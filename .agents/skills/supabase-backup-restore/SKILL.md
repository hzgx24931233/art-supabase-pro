---
name: supabase-backup-restore
description: Restore a Supabase backup snapshot into a remote Supabase project or an isolated local Supabase stack, then verify the result. Use whenever the task is 把 supabase/backups/<时间戳> 恢复/导入到远程 Supabase 项目或本地 Supabase 项目, mentions restore-supabase.ps1, restore-local-supabase.ps1, backup-supabase.ps1, 数据库备份恢复, 快照恢复, 整库迁移/项目搬迁, supabase/backups, or asks to move a Supabase project's database, Storage files, Realtime tables and Edge Functions to another project. Also use when a previous restore failed and needs to be retried or diagnosed.
---

# Supabase 备份恢复

本仓库的快照（`supabase/backups/<时间戳>/`）可以恢复到两种目标：

| 目标 | 脚本 | 用途 |
| --- | --- | --- |
| 另一个**全新空白的远程项目** | `supabase/restore-supabase.ps1` | 把整套系统搬到新项目 |
| 本机**独立 Supabase 栈** | `supabase/restore-local-supabase.ps1` | 本地复现/调试生产数据 |

两者共用同一套数据库恢复序列（`supabase/transfer-common.ps1` 的 `Get-LogicalRestorePsqlArguments`），因此本地和远端的行为一致。备份用 `supabase/backup-supabase.ps1` 生成，分发用 `package-supabase-backup.ps1` / `download-supabase-backup.ps1`。

完整操作说明见 `supabase/README.zh-CN.md`；本 skill 补充**实际操作中必须预先知道的前提**和**失败模式**。

## 第一步：只读预检（不要跳过）

恢复是长耗时的写操作，先在只读阶段把会失败的原因排除掉。

```powershell
# 1. 备份完整性：核对 manifest 与 444 个文件的 SHA-256，不连接任何远端
.\supabase\restore-supabase.ps1 -BackupPath '.\supabase\backups\20261001-103323' -TargetProjectRef '<目标ref>' -VerifyBackupOnly

# 2. 目标必须是全新空项目：脚本会拒绝来源相同、已有 public 表/Auth 用户/Storage 数据/已部署函数的目标
#    远程先确认能访问：supabase projects list --output-format json

# 3. CLI 与 Docker
supabase --version ; docker version --format '{{.Server.Version}}'

# 4. 备份里是否有 NOT VALID 约束（决定数据导入是否需要延迟约束，脚本会自动处理）
Select-String -Path .\supabase\backups\<时间戳>\database\schema.sql -Pattern '^CREATE POLICY ' | Measure-Object
(Select-String -Path .\supabase\backups\<时间戳>\database\schema.sql -Pattern 'NOT VALID').Count
```

还要确认两件事，它们决定了恢复能否连上目标（细节见 `references/pitfalls.md`）：

- **目标直连域名是否只有 IPv6**。新项目的 `db.<ref>.supabase.co` 只发布 AAAA 记录，而 Docker 容器没有 IPv6 路由。脚本检测到这一点会自动改走 IPv4 连接池（Supavisor 会话模式 5432），日志会打印 `Direct database host is IPv6-only; connecting through the IPv4 pooler ...`。看到这行是正常且期望的。
- **备份的 Storage 目录层级**。用 CLI 下载的备份是 `storage/<桶>/<桶>/<对象名>`（CLI 会额外建一层桶名目录）；脚本的 `Get-StorageBucketRoot` 自动识别两种布局。

## 流程 A：恢复到远程项目

```powershell
.\supabase\restore-supabase.ps1 `
  -BackupPath '.\supabase\backups\20261001-103323' `
  -TargetProjectRef 'abcdefghijklmnopqrst'
```

脚本会依次交互提示：数据库密码 → **完整输入目标 ref 确认**。之后自动执行：

1. `supabase link` 到临时工作目录（不会改动本仓库当前的链接）
2. 空库校验（public 表 + Auth 用户 + Storage 桶/对象 + 已部署函数都必须为 0）
3. 数据库导入：`roles.sql` → `schema.sql`（逐条提交）→ 延迟 `NOT VALID` 约束 → 数据导入（独立事务）→ 约束按原状建回 → 迁移历史
4. Realtime 发布关系 → Storage 文件 → 部署 Edge Functions

**耗时预期**：本仓库规模（615 表、2038 函数、1752 索引、2255 策略、196 MB Storage、40 个函数）约 2 小时，其中 `schema.sql` 逐条提交占大部分（通过连接池约 2–3 条/秒）。用长超时或后台运行，不要因为长时间无输出而中断。

### 自动化执行时的两个坑

脚本用 `Read-Host` 做确认门，`Read-Host` 会读取管道 stdin，所以可以非交互驱动；但 `-File` 无法直接构造 SecureString，需要一个临时 wrapper：

```powershell
# wrapper：从环境变量取密码，避免密码出现在命令行参数里
$wrapper = @'
$secure = ConvertTo-SecureString $env:RESTORE_DB_PASSWORD -AsPlainText -Force
& '<仓库路径>\supabase\restore-supabase.ps1' `
  -BackupPath '<仓库路径>\supabase\backups\<时间戳>' `
  -TargetProjectRef '<目标ref>' `
  -TargetDbPassword $secure
'@
Set-Content -LiteralPath "$env:TEMP\restore-run.ps1" -Value $wrapper -Encoding UTF8

# 确认门要求输入完整 ref
printf '<目标ref>\n' | $env:RESTORE_DB_PASSWORD='<数据库密码>'; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\restore-run.ps1"
```

把进度重定向到日志文件再轮询，因为完整运行会超过单次命令超时。

## 流程 B：恢复到本地 Supabase 栈

```powershell
.\supabase\restore-local-supabase.ps1 `
  -BackupPath '.\supabase\backups\20261001-103323' `
  -LocalRoot 'D:\supabase-transfer-test\local'
```

要点：

- `-LocalRoot` 必须是**不存在的新目录**（父目录要存在）。脚本会在其中创建独立的 `supabase/` 栈并自动 `supabase start`。
- 本地栈需要拉取整套 Supabase 镜像（数 GB）。如果镜像未缓存，首次 `supabase start` 会很久，先确认磁盘和网络。
- 默认端口（`54321` 等）被占用时，改新建 `local\supabase\config.toml` 里的端口，然后加 `-Resume` 重跑。
- 本地不需要 `supabase login`，也不会连接任何云项目。Auth 用户凭据已从分享包中移除（用 `package-supabase-backup.ps1` 打包的版本）。
- 失败后要**重建整个本地目录**再恢复：`schema.sql` 是逐条提交的，失败时目标已不是空库，`-Resume` 只适合端口/配置类中途失败。

## 恢复后立即验证

用 skill 自带的只读验收脚本，它把库和 Storage 与备份元数据自动比对：

```powershell
# 远程
$env:RESTORE_DB_PASSWORD = '<目标数据库密码>'
.\.agents\skills\supabase-backup-restore\scripts\verify-restore-state.ps1 `
  -BackupPath '.\supabase\backups\20261001-103323' `
  -TargetProjectRef '<目标ref>'

# 本地
.\.agents\skills\supabase-backup-restore\scripts\verify-restore-state.ps1 `
  -BackupPath '.\supabase\backups\20261001-103323' `
  -LocalRoot 'D:\supabase-transfer-test\local'
```

它只读，退出码 0 表示全部通过。8 项检查：schema 已导入、每个 public 表都启用 RLS、RLS 策略数与备份的 `CREATE POLICY` 数一致、Storage 桶/对象元数据数与备份一致、**没有落在"桶名重复一层"路径上的 Storage 对象**、延迟的 `NOT VALID` 约束已按原状建回、Storage 抽样逐字节 SHA-256 一致。另外报告 Auth 用户数和迁移历史行数（分享包的历史行数为 0 属正常）。

也可以只跑其中某类检查——`references/verification.md` 有可复制的 SQL，包括脚本未覆盖的编码抽查和 Realtime/函数核对。

## 恢复后必须手工补的

备份本身带不走这些，脚本会在结束时警告，但不要漏：

- **Edge Function Secrets 的值**：只有名称被记录（本仓库为 11 个：`AI_API_KEY`、`AI_BASE_URL`、`AI_MODEL`、`OPENAI_API_KEY`、`SUPABASE_ANON_KEY`、`SUPABASE_DB_URL`、`SUPABASE_JWKS`、`SUPABASE_PUBLISHABLE_KEYS`、`SUPABASE_SECRET_KEYS`、`SUPABASE_SERVICE_ROLE_KEY`、`SUPABASE_URL`），值必须重新填写。
- **`auth.identities` 不在快照里**：只恢复 `auth.users`（本次 39 条）。邮箱/密码登录可能因此不可用，需要重建 identities 后验证登录。`auth.sessions`、`auth.refresh_tokens` 同理。
- **Dashboard 专属配置**：Auth/OAuth、SMTP、邮件模板、站点 URL、回调地址、自定义域名。
- **自定义 LOGIN 角色密码**、Vault/列加密的根密钥、函数 import map 或 `deno.json`。
- **Storage 缓存策略**：走 Storage API 上传不写自定义 `cache-control`，需要时复核。

## 排错速查

| 现象 | 原因与处理 |
| --- | --- |
| `connection ... failed: Network unreachable` | 目标直连只有 IPv6 而容器无 IPv6 路由。脚本应已自动改走 IPv4 连接池；没有则检查 `supabase link` 是否成功、`pooler-url` 是否生成 |
| `out of shared memory` / `increase "max_locks_per_transaction"` | 单事务持有全部 DDL 锁撑爆共享锁表（托管项目该参数需超级用户才能改）。共享恢复序列已改为 `schema.sql` 逐条提交 |
| `violates check constraint ...`（导入数据时） | 备份数据违反了源库中 `NOT VALID` 的约束——这正是它是 `NOT VALID` 的原因。共享序列已延迟这类约束到数据之后建回 |
| `mime type application/octet-stream is not supported` | 桶设置了 `allowed_mime_types`。已改为按对象名推断 Content-Type |
| `Unsupported operation` / `Run cp -r <src> <dst> ...` | 当前 CLI 不支持把本地文件上传到远端（只支持下载）。自动回退 Storage API 逐个上传，日志里的这条 warning 属正常 |
| Storage 对象数翻倍、出现 `attachments/attachments/...` | 备份的桶目录层级被当成了对象名的一部分。已由 `Get-StorageBucketRoot` 修正；若已产生错误对象，用 `references/verification.md` 的检查定位并删除 |
| `must be owner of table messages` 之类 | 延迟约束的属主过滤失效，会去动 Supabase 托管 schema（`realtime`/`auth`/`storage`）。这些表的属主不是 `postgres`，应被 `pg_get_userbyid(c.relowner) = current_user` 排除 |
| 恢复中途失败 | 不要在原目标上重试（已非空库，空库校验会拒绝）。换**新的空项目**（或新的本地目录）重跑完整恢复 |

更详细的失败模式、真实报错文本和修复位置见 `references/pitfalls.md`。

## 参考文档

- `references/pitfalls.md` — 五类已修复故障的完整症状、根因、代码位置与验证方式。
- `references/verification.md` — 验收清单与可复制的核查 SQL（含编码抽查、Realtime、函数数量、错误 Storage 对象清理）。
- `scripts/verify-restore-state.ps1` — 只读验收脚本（远程/本地通用）。
