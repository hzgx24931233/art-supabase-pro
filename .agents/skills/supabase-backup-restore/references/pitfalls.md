# 已修复故障与排查依据

本文记录 art-supabase-pro 恢复流程中**已实际踩到并已修复**的五类故障。远端和本地恢复共用同一套序列（`supabase/transfer-common.ps1` 的 `Get-LogicalRestorePsqlArguments` / `Get-StorageBucketRoot`），所以这些修复对两条流程同时生效。

如果再次遇到这些报错，先确认 `supabase/transfer-common.ps1`、`supabase/restore-supabase.ps1`、`supabase/restore-local-supabase.ps1` 未被回退到修复前的版本。

---

## 1. 目标数据库主机只有 IPv6，Docker 容器连不上

**症状**

```
psql: error: connection to server at "db.<ref>.supabase.co" (2406:da14:...) port 5432 failed: Network unreachable
	Is the server running on that host and accepting TCP/IP connections?
Database restore failed; Storage and Functions were not imported.
```

**根因**

新 Supabase 项目对直连域名 `db.<ref>.supabase.co` 只发布 AAAA 记录，没有 A 记录。宿主机自己能连（有 IPv6 出口），但 Docker Desktop 默认 bridge 网络没有 IPv6 路由，容器内的 psql 必然失败。

诊断证据：

```bash
nslookup db.<ref>.supabase.co                  # 只返回 IPv6 Address
docker run --rm postgres:17-alpine sh -c "getent ahostsv4 db.<ref>.supabase.co"   # 无 IPv4 输出
```

**修复**

`Get-LinkedDatabaseConnection`（`supabase/transfer-common.ps1`）先用 `Test-HostResolvesOverIpv4` 检查直连主机是否有 A 记录；没有则改用 `supabase link` 记录的 IPv4 连接池（`Get-PoolerDatabaseConnection` 读 `supabase/.temp/pooler-url`）。

两个关键约束：

- **只接受会话模式 5432**。事务模式 6543 不会把 `session_replication_role` 保留到数据导入，会破坏触发器/外键抑制。
- **连接池用户名必须属于目标项目**（`postgres.<ref>` 且 ref 匹配），防止读到过期或残留的 `pooler-url` 而连错库。

**验证方式**：日志出现 `Direct database host is IPv6-only; connecting through the IPv4 pooler aws-0-<region>.pooler.supabase.com...`。连接池主机应能解析出 IPv4。

**注意**：`max_locks_per_transaction` 等参数在托管项目无法通过 `ALTER SYSTEM` 修改（`postgres` 角色不是超级用户），所以不要试图用改参数绕过问题 2。

---

## 2. 共享锁表耗尽（整个导入包在一个事务里）

**症状**

```
psql:/backup/database/schema.sql:176436: ERROR:  out of shared memory
HINT:  You might need to increase "max_locks_per_transaction".
```

**根因**

原来用 `psql --single-transaction` 把整个导入包在一个事务里。schema 规模大时（本仓库 615 张表、2038 个函数、1752 个索引、2255 条策略、3935 条 `ALTER TABLE`，约 1 万个 DDL 对象），事务要一直持有所有对象的锁。

托管项目容量：`max_locks_per_transaction = 64` × `max_connections = 60` ≈ 4800 个锁槽，远不够。失败点约在 `schema.sql` 的 71%（行 176436 / 共 247957），即建索引阶段。

**修复**

`Get-LogicalRestorePsqlArguments` 让 `schema.sql` **逐条提交**（不再用 `--single-transaction`），锁在每条语句后释放。**数据导入仍保留自己的事务**（`--command 'BEGIN'` / `--command 'COMMIT'` 夹住 `data.sql`），保持"业务数据全有或全无"。`ON_ERROR_STOP=1` 保证出错即停。

**验证方式**：用临时 Postgres 验证过——数据导入中途报错时，schema 保留、数据回滚。远端实测：跑到原先失败点后继续通过。

**注意**：逐条提交意味着 `schema.sql` 中途失败会留下"不完整的 schema"，此时目标已不是空库，空库校验会拒绝重试。这属于设计取舍：恢复失败一律换新的空目标重跑。

---

## 3. `NOT VALID` 检查约束拒绝源库自己的数据

**症状**

```
psql:/backup/database/data.sql:9485: ERROR:  new row for relation "mdm_activity_formula" violates check constraint "mdm_activity_formula_activity_types_check"
DETAIL:  Failing row contains (efbd4b4a-..., ..., [{"kind": "number", "value": "1"}]).
```

**根因**

源库里该约束是 `NOT VALID`：

```sql
ALTER TABLE "public"."mdm_activity_formula"
    ADD CONSTRAINT "mdm_activity_formula_activity_types_check" CHECK (...) NOT VALID;
```

`NOT VALID` 的含义正是"已有行**从未**校验过"，所以源库本来就存在违反它的遗留行。但 `NOT VALID` 对**新写入**的行仍然生效，而 `session_replication_role = replica` 只抑制触发器和规则、**不抑制 CHECK 约束**。于是备份自己的数据被自己的约束拒绝。

**修复**

`Get-LogicalRestorePsqlArguments` 在 `schema.sql` 之后、数据导入之前，把本次恢复**拥有的** `NOT VALID` 检查约束暂存并删除，数据导入并提交后再按原定义建回（还原成源库的"未校验"状态）：

```sql
-- 暂存 + 删除
create temp table _restore_not_valid_checks as
select format('alter table %I.%I add constraint %I %s', ...) as readd,
       format('alter table %I.%I drop constraint %I', ...) as drop_stmt
from pg_constraint con ...
where con.contype = 'c' and not con.convalidated
  and pg_catalog.pg_get_userbyid(c.relowner) = current_user;
-- 数据导入后
do $$ ... execute r.readd ... $$;
```

两个关键点：

- **必须按表属主过滤**（`pg_get_userbyid(c.relowner) = current_user`）。Supabase 托管的 `realtime.messages_payload_exclusive` 也是 `NOT VALID`，但它属主不是 `postgres`；不过滤会报 `must be owner of table messages`。
- **PostgreSQL 17 的 `pg_get_constraintdef()` 已包含 `NOT VALID` 字样**，所以回建时直接 `format('... add constraint %I %s', ..., pg_get_constraintdef(oid))`，不要再追加 `NOT VALID`，否则语法错误。

**验证方式**：导入后 `mdm_activity_formula` 应有 12 行（含被约束拒绝过的遗留行），两个约束的 `convalidated = false`；同时**新插入违规行仍被拒绝**，证明约束语义未丢失。

---

## 4. Storage API 回退上传的 MIME 类型

**症状**

```
Invoke-WebRequest : {"statusCode":"415","error":"invalid_mime_type",
"message":"mime type application/octet-stream is not supported","code":"InvalidMimeType"}
```

**根因**

`storage cp` 失败后会回退到 Storage API 逐个上传，而 `Invoke-StorageObjectUpload` 固定发送 `Content-Type: application/octet-stream`。设置了 `allowed_mime_types` 的桶（如 `ai-ui-design-reference` 只允许 `image/png`、`image/jpeg`、`image/webp`）会直接拒绝。

**修复**

`transfer-common.ps1` 新增 `Get-StorageContentType`，按对象名扩展名推断 Content-Type（png/jpg/webp/pdf/docx/xlsx/mp4/... ），未知扩展名回退 `application/octet-stream`。未设置 MIME 限制的桶（如 `attachments`）不受影响。

**验证方式**：上传后 `storage.objects.metadata->>'mimetype'` 应是真实类型（`image/png` 等），而不是 `application/octet-stream`；0 字节的 `.emptyFolderPlaceholder` 与无扩展名对象仍为 `application/octet-stream` 属正常。

---

## 5. Storage 对象名多出一层桶目录

**症状**

对象能上传成功，但 `storage.objects` 行数翻倍，出现 `attachments/attachments/...` 这样以桶名开头的路径；原对象没被更新，而是被**新建**了一份。

**根因**

备份下载用 `storage cp ss:///<桶> . --recursive`，CLI 会额外创建一个以桶名命名的目录，所以本地布局是：

```
storage/<桶>/<桶>/<对象名>          # 备份里的实际层级
storage/<桶>/<对象名>               # 恢复脚本原先假设的层级
```

而数据库里的对象名**不含**桶名前缀。于是恢复时 `相对路径` 被整体当成对象名，多带了一层桶名。本次实测：`ai-ui-design-reference` 5 个、`attachments` 294 个、`mdm-accessory-processing` 57 个文件，与数据库对象名严格是 `<桶>/` + `<对象名>` 的一一对应。

**修复**

`Get-StorageBucketRoot` 判断 `<桶目录>/<桶名>` 是否存在，存在则用它作为对象根（CLI 布局），否则用桶目录本身（Storage API 下载布局），之后一律按该根计算相对路径。两个恢复脚本都改用它，CLI 主路径和 API 回退路径也因此一致。

**验证方式**：恢复后不应存在 `name like bucket_id || '/%'` 的对象；`storage.objects` 行数应等于备份 `metadata/storage-object-counts.json` 的合计。

**清理已产生的错误对象**：见 `verification.md` 的"清理误建的 Storage 对象"，用 Storage API 批量 DELETE（带 `prefixes` 数组），元数据和实际字节会一起删除。

---

## 6. 恢复后所有人都无法登录（接收者安全版本不含凭据）

**症状**

恢复"成功"，表和数据都在，但任何账号用原密码登录都失败（`Invalid login credentials`）。前端的 Supabase URL/key 都指向新项目，连接本身是通的。

**根因**

备份是**接收者安全版本**（`manifest.json` 的 `recipient_safe_auth` 为 `true`）。`package-supabase-backup.ps1` 会清除 Auth 密码哈希、identities、会话、刷新令牌和一次性令牌，并去掉迁移历史内容与托管 schema 快照；`migration-history-data.sql` 只剩一行占位注释。**原密码哈希不存在于这份备份的任何位置**，因此不可恢复——这不是恢复过程丢的，也不是配置问题。

判断一份备份是不是接收者版本：

```powershell
# true 即接收者安全版本；所有者保管的原始备份为 false 或没有该字段
(Get-Content -Raw supabase\backups\<时间戳>\manifest.json | ConvertFrom-Json).recipient_safe_auth
Test-Path supabase\backups\<时间戳>\database\managed-schema-snapshot.sql   # 接收者版本为 False
```

**诊断 SQL**

```sql
select
  (select count(*) from auth.users)                                                as users,
  (select count(*) from auth.identities)                                           as identities,
  (select count(*) from auth.users where encrypted_password is not null)           as with_password,
  (select count(*) from auth.users where last_sign_in_at is not null)              as ever_signed_in
from (select 1) t;
-- 接收者版本的典型结果：users=39, identities=0, with_password=0, ever_signed_in=35
-- ever_signed_in 很大而 with_password=0，就是凭据被清除的signature
```

### 伴随问题：读任何用户都返回 500

如果 Admin API 读用户报 `500 {"error_code":"unexpected_failure","msg":"Database error loading user"}`（列用户则是 `Database error finding users`），而**查一个不存在的用户返回 404**，说明 GoTrue 本身正常，是**扫描已有的用户行时失败**。

根因是**托管 auth schema 的版本差异**：`supabase db dump` 导出的 `auth.users` 里，下面这些列在源项目是 NULL，而目标项目较新的 GoTrue 把它们当作非空字符串扫描，NULL 直接让读取失败：

`encrypted_password`、`confirmation_token`、`email_change`、`email_change_token_current`、`email_change_token_new`、`phone_change`、`phone_change_token`、`reauthentication_token`、`recovery_token`

定位方法：建一个临时用户（GoTrue 自己写的行保证格式正确），与源用户行做逐列 diff，只打印有差异的列——上面这些正是"探针是空串、源行是 NULL"的那批：

```sql
with probe as (select to_jsonb(p) as j from auth.users p where p.id = '<探针 id>'::uuid),
     src   as (select to_jsonb(s) as j from auth.users s where s.id = '<源用户 id>'::uuid)
select k.key, probe.j->>k.key as probe_value, src.j->>k.key as source_value
from probe, src, lateral jsonb_object_keys(probe.j) as k(key)
where (probe.j->>k.key) is distinct from (src.j->>k.key) order by k.key;
```

```sql
update auth.users set
  confirmation_token = coalesce(confirmation_token, ''),
  email_change = coalesce(email_change, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  email_change_token_new = coalesce(email_change_token_new, ''),
  phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, ''),
  reauthentication_token = coalesce(reauthentication_token, ''),
  recovery_token = coalesce(recovery_token, ''),
  encrypted_password = coalesce(encrypted_password, '');
```

**这一步必须在设密码之前做**，否则 Admin API 自己就是 500，没法用它设密码。

另有一个容易误判的障碍：`email_confirmed_at` 为 NULL 的账号（例如走邀请流程创建、但没配 SMTP 所以确认链接没发出去的账号）登录会被拒（HTTP **400**），与密码无关。需要时 `update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now())`。

**修复步骤一：补齐 `auth.identities`**

GoTrue 的 email identity 格式（可用 Admin API 建一个临时用户、读回 `auth.identities` 行来确认，用完删除）。注意 `email` 是 generated 列，直接插入会报 `cannot insert a non-DEFAULT value into column "email"`：

```sql
begin;
insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select
  u.id::text,
  u.id,
  jsonb_build_object(
    'sub', u.id::text,
    'email', u.email,
    'email_verified', (u.email_confirmed_at is not null),
    'phone_verified', (u.phone_confirmed_at is not null)
  ),
  'email',
  u.last_sign_in_at,
  u.created_at,
  coalesce(u.updated_at, u.created_at)
from auth.users u
where u.email is not null
  and not exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email');
commit;
```

这一步是必须的：不仅是密码登录的前提，应用侧"登录方式管理"界面也依赖 `identities` 数据。

**修复步骤二：重建密码**（三者选一）

1. Admin API 直接设密码（需要用户知道新密码）：
   `PUT https://<ref>.supabase.co/auth/v1/admin/users/{id}`，body `{"password":"<新密码>"}`，带 `apikey` + `Authorization: Bearer <service_role>`。
2. 配好 Dashboard 的 SMTP 与 Site URL/Redirect URLs 后，让用户走"忘记密码"自助重置；或先用 Admin API `generate_link` 产出重置链接手动分发。
3. **想保留所有人的原密码，只能用所有者保管的原始备份重新恢复**（该备份含真实密码哈希与 `managed-schema-snapshot.sql`）。恢复到新项目后，先前的 identities/密码修复就不需要了。

**验证方式**：用一个临时用户（Admin API 创建 → 真实调用 `POST /auth/v1/token?grant_type=password` → 删除）确认密码登录链路可用，再处理真实账号。批量处理完要独立核对，不要只看 API 的 200：

```sql
-- 直接确认写入的哈希就是目标密码（bcrypt 每次盐不同，不能比对字符串）
select count(*) as users,
       count(*) filter (where crypt('123456', encrypted_password) = encrypted_password) as matches_target
from auth.users;
```

再用真实登录验证三种情形：已确认账号用新密码应成功、错误密码应被拒（HTTP 400）、未确认邮箱的账号应被拒。登录测试后记得 `POST /auth/v1/logout`，避免留下会话。

排查时注意 PowerShell 的一个陷阱：函数里若混用 `Write-Output` 记录日志和 `return $true`，`if (Test-Login ...)` 判断的是"非空数组"因而恒为真，会得到看似通过的假阳性——日志用 `Write-Host`，让返回值成为唯一输出。

## 补充：CLI 的 `storage cp` 不支持本地上传到远端

```
Unsupported operation
Run cp -r <src> <dst> to copy between local directories.
```

`supabase storage cp <本地文件> ss:///<桶>/<对象>`（CLI 2.118.0）无论传目录还是单个文件、无论带不带 `--project-ref` 都会报此错；下载方向（`ss:///<桶>` → `.`）正常，备份脚本正是用下载方向。因此**远端恢复的 Storage 实际上全部走 Storage API 回退路径**，日志里每个桶都会有一条 `Supabase CLI Storage upload failed ... retrying through the Storage API` 警告，这属正常现象。`--local` 的本地恢复方向是否同样受限取决于 CLI 版本，脚本对两种结果都做了回退。

另外，Storage API 上传不写自定义 `cache-control`（CLI 路径默认 `max-age=3600`），需要时恢复后自行复核缓存策略。
