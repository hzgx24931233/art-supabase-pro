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

- **Edge Function Secrets 的值**：备份只记录名称和 SHA-256 指纹，值不可读回。但恢复后**不要**照着清单逐个重填——先 `supabase secrets list --project-ref <ref>` 看新项目已有的项。Supabase 会按新项目自动注入平台级默认 secrets（`SUPABASE_URL`、`SUPABASE_ANON_KEY`、`SUPABASE_SERVICE_ROLE_KEY`、`SUPABASE_DB_URL`、`SUPABASE_JWKS`、`SUPABASE_PUBLISHABLE_KEYS`、`SUPABASE_SECRET_KEYS`），这些已经是对的，手动覆盖反而有害：`SUPABASE_PUBLISHABLE_KEYS` 和 `SUPABASE_SECRET_KEYS` 的代码期望是含 `default` 字段的 JSON（`readKeyMap` 里 `JSON.parse(raw).default`），塞裸 key 会让解析失败。真正需要手工补的通常只有业务侧凭据（本仓库为 `AI_API_KEY`、`AI_BASE_URL`、`AI_MODEL`、`OPENAI_API_KEY` 四个 AI 服务配置），这些值只能由项目所有者提供。缺失时 AI 功能会优雅降级并给出明确提示，其余业务功能正常。
- **登录凭据不会随快照恢复**。先看 `manifest.json` 的 `recipient_safe_auth`：为 `true` 说明这是**接收者安全版本**，打包时已清除 Auth 密码哈希、identities、会话和一次性令牌（判断特征：`migration-history-data.sql` 是占位注释、没有 `managed-schema-snapshot.sql`）。这类备份恢复后 `auth.users` 行数正常，但 `encrypted_password` 全为 NULL、`auth.identities` 为 0，**任何人都无法用原密码登录**——原密码哈希不存在于备份中的任何位置，不可恢复。
  修复分两步：先按 GoTrue 的格式补齐 `auth.identities`（`provider='email'`、`provider_id` = user id、`identity_data` 含 `sub`/`email`/`email_verified`/`phone_verified`；注意 `auth.identities.email` 是 generated 列，不能显式插入），再重建密码（Admin API `PUT /auth/v1/admin/users/{id}` 设 `password`，或配置 SMTP 后让用户自助重置）。想保留所有人的原密码，只能改用**所有者保管的原始备份**重新恢复。
  排查与修复的完整 SQL 见 `references/pitfalls.md`；`auth.sessions`、`auth.refresh_tokens` 缺失只影响既有会话，不影响新登录。
- **Dashboard 专属配置**：Auth/OAuth、SMTP、邮件模板、站点 URL、回调地址、自定义域名。
- **自定义 LOGIN 角色密码**、Vault/列加密的根密钥、函数 import map 或 `deno.json`。
- **Storage 缓存策略**：走 Storage API 上传不写自定义 `cache-control`，需要时复核。

## 把应用指向新项目

恢复完成后应用**默认仍指向源项目**——项目 ref 硬编码在多处。切换时逐项处理，并用 `git grep -l "<旧ref>"` 自查遗漏：

| 位置 | 说明 |
| --- | --- |
| `.env` 的 `VITE_SUPABASE_URL` / `VITE_SUPABASE_KEY` | 前端配置入口。变量名是 `VITE_SUPABASE_KEY`，不是 `VITE_SUPABASE_PUBLISHABLE_KEY` |
| `Dockerfile` 的 `ARG VITE_SUPABASE_*` | 构建期优先级最高，会覆盖 `.env`，必须同步 |
| `docker-compose.yml` 的 `build.args` | 同上，会覆盖 Dockerfile 默认值 |
| `nginx.conf` 的 `proxy_pass` **和** `proxy_set_header Host` | 必须一起改；只改 `proxy_pass` 会让上游收到的 Host 仍是旧项目 |
| `src/views/data-center/supabase-ai-assistant/` | 两处 `overview.projectRef` 的兜底文案 |
| `supabase/functions/sync-user`、`register-and-sync-user` | `allowedOrigins` 白名单里的项目 URL，改完**需重新部署** |
| `supabase/functions/ai-project-assistant` | `PROJECT_REF` 用于调 Management API 查**自己项目**的函数列表，改完**需重新部署**；也可改为从 `Deno.env.get('SUPABASE_URL')` 派生，之后迁移不必再改 |
| `supabase/backup-supabase.ps1` | `-ProjectRef` 的默认值 |
| `tests/e2e/*.spec.ts`、`tests/powershell/supabase-cli-auth.test.ps1` | 测试中写死的项目 ref 与 URL |
| `docs/` | 前端构建产物，内联了旧 URL/ref，重新构建即可更新 |

**不要改** `.mcp.json` 和 `AGENTS.md`：它们把本仓库的 agent 工具作用域绑定在源项目上，是仓库的刻意约定，与"应用连哪个项目"是两回事。

`VITE_*` 是**构建期**变量，Vite 会把值内联进产物，所以改完必须重新构建（Docker 部署要 `--build` 重建镜像），运行期加 `-e` 无效。

改完用新项目的 publishable key 做一次只读验证即可确认配置正确：`GET /auth/v1/settings` 返回 200；REST 查业务表返回 `[]` 而不是 401，说明 key 有效且 RLS 正常拦截匿名访问（这是期望行为，不是故障）。注意 `/rest/v1/` 这个 OpenAPI 根路径本身对 publishable key 返回 401，不代表配置有问题。

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
