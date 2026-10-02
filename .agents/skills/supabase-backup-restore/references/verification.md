# 恢复验收清单

恢复完成后不要只看脚本的 `Restore completed.`，要独立核对库和 Storage。本文给出自动验收脚本和可复制的手工核查 SQL。

## 一、自动验收（首选）

`.agents/skills/supabase-backup-restore/scripts/verify-restore-state.ps1` 是只读的，退出码 0 表示全部通过。

```powershell
# 远程项目
$env:RESTORE_DB_PASSWORD = '<目标数据库密码>'
.\.agents\skills\supabase-backup-restore\scripts\verify-restore-state.ps1 `
  -BackupPath '.\supabase\backups\20261001-103323' `
  -TargetProjectRef 'nvzlwcutsqptngyqfzqs'

# 本地栈
.\.agents\skills\supabase-backup-restore\scripts\verify-restore-state.ps1 `
  -BackupPath '.\supabase\backups\20261001-103323' `
  -LocalRoot 'D:\supabase-transfer-test\local'

# 只查状态、跳过 Storage 逐字节抽查（默认每桶抽 2 个）
.\.agents\skills\supabase-backup-restore\scripts\verify-restore-state.ps1 -BackupPath '<备份>' -TargetProjectRef '<ref>' -ByteSampleCount 0
```

它先跑 `Assert-BackupManifest` 重新校验备份（含全部文件 SHA-256），再检查：

| 检查 | 通过标准 |
| --- | --- |
| Application schema imported | public 表数 > 0 |
| RLS enabled on every public table | `relkind='r'` 的 public 表中未启用 RLS 的数量 = 0 |
| RLS policies restored | public + app_private 策略数 = 备份 `schema.sql` 中 `CREATE POLICY` 语句数 |
| Storage bucket metadata restored | `storage.buckets` 行数 = `metadata/storage-buckets.json` 条目数 |
| Storage object metadata restored | `storage.objects` 行数 = `metadata/storage-object-counts.json` 合计 |
| No Storage objects at doubled bucket path | `name like bucket_id \|\| '/%'` 的行数 = 0 |
| Deferred NOT VALID constraints restored | 本恢复拥有的 `NOT VALID` 检查约束数 ≥ 备份 schema 声明的数量 |
| Storage bytes match the backup | 抽样对象回下载后 SHA-256 与备份文件一致 |

它还会打印 `auth.users` 行数与迁移历史行数作为参考信息（不判定通过失败）。

## 二、连接信息怎么取

自动脚本内部已经处理；手工执行 SQL 时按下面方式取连接。

**远程项目**（直连域名通常只有 IPv6，`Docker` 容器连不上，要用连接池）：

```powershell
# 在临时目录 link 后读取 CLI 记录的连接池地址（注意不要打印带密码的完整串）
$stage = Join-Path $env:TEMP ('link-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $stage 'supabase') -Force | Out-Null
Copy-Item '.\supabase\backups\<时间戳>\config.toml' (Join-Path $stage 'supabase\config.toml')
Push-Location $stage ; supabase link --project-ref '<目标ref>' ; Pop-Location
Get-Content "$stage\supabase\.temp\pooler-url"
# postgresql://postgres.<ref>@aws-0-<region>.pooler.supabase.com:5432/postgres
```

**本地栈**：在 `-LocalRoot` 目录执行 `supabase status --output json`，取 `DB_URL`（形如 `postgresql://postgres:postgres@127.0.0.1:54322/postgres`）。从容器访问宿主机要用 `host=host.docker.internal` 并加 `--add-host host.docker.internal:host-gateway`。

统一的执行方式（本仓库沿用 `postgres:17-alpine` 容器里的 psql）：

```bash
docker run --rm -e PGPASSWORD postgres:17-alpine \
  psql "host=<主机> port=5432 dbname=postgres user=<用户> sslmode=require" \
  -c "<SQL>"
```

## 三、手工核查 SQL

### 核心计数

```sql
select
  (select count(*) from pg_tables where schemaname='public')                        as public_tables,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public')                                                      as public_functions,
  (select count(*) from pg_policies where schemaname='public')                      as public_policies,
  (select count(*) from pg_policies where schemaname='app_private')                 as app_private_policies,
  (select count(*) from auth.users)                                                 as auth_users,
  (select count(*) from storage.buckets)                                            as buckets,
  (select count(*) from storage.objects)                                            as storage_objects,
  (select count(*) from storage.objects where name like bucket_id || '/%')          as spurious_objects;
```

### RLS 覆盖

```sql
-- 期望 0 行：public 下所有普通表都应启用 RLS
select n.nspname, c.relname
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
```

### 延迟的 NOT VALID 约束

```sql
-- 应列出源库原有的 NOT VALID 约束，且 convalidated = false
select n.nspname, c.relname, con.conname, con.convalidated
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where con.contype = 'c' and not con.convalidated
  and pg_catalog.pg_get_userbyid(c.relowner) = current_user
order by 1, 2, 3;

-- 约束对新数据仍然生效（应报错，验证完记得回滚/清理）
-- insert into public.mdm_activity_formula (...) values (...);
```

### 中文编码抽查

**重要**：psql 输出经过 Windows 控制台可能显示成乱码（例如 `准备时间` 显示为 `鍑嗗囨椂闂�`），那是控制台编码问题，不代表库内数据错误。用 hex 比对或服务端比较来判断：

```sql
-- 期望 SY-001 = e58786e5a487e697b6e997b428e883bde58a9b29  即「准备时间(能力)」
select code || '  ' || encode(convert_to(name,'UTF8'),'hex')
from public.mdm_activity_formula where code in ('SY-001','SY-004') order by code;

-- 服务端比较，不受控制台编码影响
select 'chinese_prefix_matches=' || count(*)
from public.mdm_activity_formula where name like '准备%';
```

### Realtime 发布关系

```sql
select pubname, schemaname, tablename
from pg_publication_tables where pubname = 'supabase_realtime'
order by tablename;
-- 应与 metadata/realtime-publication-tables.json 一致
```

### 迁移历史

```sql
select case when to_regclass('supabase_migrations.schema_migrations') is null
            then 'missing' else (select count(*)::text from supabase_migrations.schema_migrations) end;
-- 表应存在；分享包（recipient package）的历史数据被刻意省略，行数为 0 属正常
```

### Edge Functions

```powershell
supabase functions list --project-ref '<目标ref>' --output json
# 数量应与 metadata/functions.json 的条目数一致（本仓库为 40）
```

注意：`supabase` 命令在仓库目录执行会在 `supabase/.temp/linked-project.json` 留下目标项目的缓存记录。如需保持仓库原有的链接状态，用完删掉该文件。

## 四、清理误建的 Storage 对象

如果恢复用了修复前的脚本，会产生 `name like bucket_id || '/%'` 的错误对象。先定位：

```sql
select bucket_id, count(*) from storage.objects
where name like bucket_id || '/%' group by 1 order by 1;
```

再用 Storage API 批量删除（元数据和实际字节一起删除）。`DELETE /storage/v1/object/<桶>` 的 body 用 `prefixes` 数组：

```powershell
# 复用仓库的 key 解析（已处理 Windows PowerShell 把顶层 JSON 数组折叠成单个对象的怪癖）
. .\supabase\transfer-common.ps1
Enable-SystemProxyForSupabaseCli | Out-Null
$key = Get-SupabaseServiceRoleKey -ProjectRef '<目标ref>'

$bucket = '<桶名>'
$headers = New-StorageAdminHeaders -Key $key
$body = @{ prefixes = @('<对象名1>','<对象名2>') } | ConvertTo-Json -Compress
Invoke-RestMethod -Method Delete `
  -Uri "https://<目标ref>.supabase.co/storage/v1/object/$([uri]::EscapeDataString($bucket))" `
  -Headers $headers -Body $body -ContentType 'application/json'
```

删除后重跑验收脚本，"No Storage objects at doubled bucket path" 应为 PASS，且 `storage.objects` 行数回到备份的期望值。

## 五、参考基线

以 `supabase/backups/20261001-103323` → 项目 `nvzlwcutsqptngyqfzqs` 的实测结果作为对照基线（该备份来自迁移前的旧项目）：

| 指标 | 值 |
| --- | --- |
| public 表 | 522 |
| public 函数 | 1304 |
| RLS 策略 | 2252（public）+ 3（app_private）= 2255，与备份 `CREATE POLICY` 数一致 |
| 未启用 RLS 的 public 表 | 0 |
| `app_private` 表 | 88 |
| Auth 用户 | 39（`auth.identities` 为 0，快照不含） |
| Storage 桶 / 对象 | 3 / 356（196 MB） |
| 延迟的 NOT VALID 约束 | 2（均在 `mdm_activity_formula`） |
| Edge Functions | 40 |
| 迁移历史行数 | 0（分享包省略） |
| 数据导入 | 621 个 COPY 块，0 错误 |

恢复耗时参考：数据库 schema 逐条提交约占 80 分钟，数据导入约 25 分钟，196 MB Storage 约 10 分钟，40 个函数部署约 15 分钟。
