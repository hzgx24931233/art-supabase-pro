# Docker 部署说明

面向本仓库（Vue 3 + TypeScript + Vite + Supabase，产物为静态站点）的容器化方案。构建期执行 `vite build` 产出静态资源，运行期用 `nginx:alpine` 托管，并把 `/api/**` 反向代理到 Supabase。

## 1. 交付物

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 多阶段构建：`node:24-alpine` 构建 → `nginx:alpine` 运行 |
| `nginx.conf` | History 路由回退、`/api` → Supabase 反代、缓存与 gzip 策略 |
| `.dockerignore` | 排除 `node_modules`、`.git`、`docs`（本地产物目录，含 12 个子仓共约 780MB） |
| `docker-compose.yml` | 单服务编排，便于后续与其它服务同网络编排 |
| `DOCKER.md` | 本文档 |

## 2. 前置条件

- Docker 20.10+ / Docker Compose v2+（本方案在 Docker 29.8.1 + Compose v5.5.1 上验证）。
- 构建机可用内存 ≥ 4GB（monaco / three / echarts / pdfjs 等体积较大）。
- **子模块源码必须存在**：`modules/art-supabase-*` 需要有各自的 `src/`，否则页面会缺功能或构建失败。

```bash
# 克隆时带上子模块
git clone --recurse-submodules <repo-url>
# 已克隆过则补齐 / 更新
git submodule update --init --recursive
```

镜像里只执行 `pnpm build`（= `vite build`）。宿主构建直接引用各子仓的 `src/`，不需要各子仓单独安装依赖或构建，所以 `pnpm build:all` 与 `pnpm modules:build` 都不需要跑。

## 3. 快速开始

```bash
# 1) 构建镜像（仓库根目录执行，Dockerfile 与 .dockerignore 都在根目录）
docker build -t art-supabase-pro:1.0.0 .

# 2) 启动容器（宿主 8080 映射到容器 80）
docker run -d --name art-supabase-pro -p 8080:80 --restart unless-stopped art-supabase-pro:1.0.0

# 3) 验证
curl -I http://127.0.0.1:8080/
curl -s http://127.0.0.1:8080/api/auth/v1/health
```

浏览器访问 `http://<宿主机IP>:8080/`。

## 4. 命令手册

### 4.1 构建镜像

```bash
# 基础构建
docker build -t art-supabase-pro:1.0.0 .

# 覆盖构建期变量（VITE_* 会被内联进静态产物，改完必须重新 build）
docker build \
  --build-arg VITE_BASE_URL=/ \
  --build-arg VITE_SUPABASE_URL=https://nvzlwcutsqptngyqfzqs.supabase.co \
  --build-arg VITE_SUPABASE_KEY=sb_publishable_xxxxxxxx \
  --build-arg VITE_BUILD_COMPRESS=true \
  -t art-supabase-pro:1.0.0 .

# 带构建分析输出（排查构建失败时更清楚）
docker build --progress=plain -t art-supabase-pro:1.0.0 .

# 跨架构构建（例如在 x64 机器上出 arm64 镜像）
docker buildx build --platform linux/amd64,linux/arm64 -t art-supabase-pro:1.0.0 --push .
```

### 4.2 启动 / 重启 / 停止

```bash
# 前台启动（调试用，Ctrl+C 退出并停止容器）
docker run --rm -it --name art-supabase-pro -p 8080:80 art-supabase-pro:1.0.0

# 后台启动
docker run -d --name art-supabase-pro -p 8080:80 --restart unless-stopped art-supabase-pro:1.0.0

# 重启
docker restart art-supabase-pro

# 停止（保留容器）
docker stop art-supabase-pro

# 启动已停止的容器
docker start art-supabase-pro
```

### 4.3 查看日志与状态

```bash
# 实时日志（nginx access/error）
docker logs -f art-supabase-pro
docker logs --tail 200 art-supabase-pro

# 健康状态（healthy / unhealthy / starting）
docker inspect --format '{{.State.Health.Status}}' art-supabase-pro

# 端口与挂载信息
docker port art-supabase-pro
docker inspect art-supabase-pro

# 进容器排查（nginx -t 校验配置、看磁盘上的产物）
docker exec -it art-supabase-pro sh
docker exec art-supabase-pro nginx -t
docker exec art-supabase-pro ls -l /usr/share/nginx/html
```

### 4.4 删除容器与镜像

```bash
# 删除容器（-f 会先停止）
docker rm -f art-supabase-pro

# 删除镜像
docker rmi art-supabase-pro:1.0.0

# 清理悬空镜像与构建缓存
docker image prune -f
docker builder prune -f
```

### 4.5 docker-compose 方式

```bash
# 构建并启动（改过源码或构建参数后必须带 --build）
docker compose up -d --build

# 查看状态（含健康检查）
docker compose ps

# 日志 / 重启
docker compose logs -f web
docker compose restart web

# 停止并删除容器与网络（镜像保留）
docker compose down
```

## 5. 验证清单

```bash
# 1) 首页：200 + text/html + Cache-Control: no-cache
curl -I http://127.0.0.1:8080/

# 2) 带 hash 的静态资源：200 + long max-age（文件名取自首页 index.html）
curl -I http://127.0.0.1:8080/assets/index-xxxxxxxx.js

# 3) History 回退：不存在的路径同样返回 200 + text/html（SPA 入口）
curl -I http://127.0.0.1:8080/some/deep/route

# 4) 缺失的构建产物必须是 404，而不是回退成 index.html
curl -o /dev/null -s -w '%{http_code}\n' http://127.0.0.1:8080/assets/not-exist.js

# 5) /api 反代连通 Supabase
#    不带 apikey → 401 {"message":"No API key found in request"}（说明已到达 Supabase 网关）
curl -s http://127.0.0.1:8080/api/rest/v1/
#    带 publishable key → 200 {"version":...,"name":"GoTrue"}（上游 TLS 校验、路径改写均正常）
curl -s -H 'apikey: sb_publishable_i-GAe_-FPQ5mkfEhDXhWLw_kcLsXcO2' \
  http://127.0.0.1:8080/api/auth/v1/health

# 6) 容器内配置校验
docker exec art-supabase-pro nginx -t
```

## 6. 注意事项

### 6.1 打包环境变量在构建期固化

- `VITE_*` 是**构建期**变量，Vite 会把它们内联进产物。容器运行期再加 `-e VITE_SUPABASE_URL=...` **完全无效**，必须重新 `docker build`（compose 用 `--build`）。多环境请用「一个环境一个镜像 tag」。
- 覆盖优先级：`--build-arg` / compose `args`（进程环境）> `.env.production` > `.env`。依据是 Vite `loadEnv` 先用 `.env*` 文件，再用 `process.env` 里的同名前缀变量覆盖（`node_modules/vite/dist/node/chunks/node.js` 的 `loadEnv` 实现）。
- 已提交的 `.env` 提供 `VITE_SUPABASE_URL` / `VITE_SUPABASE_KEY` / `VITE_OUT_DIR=docs`，`.env.production` 提供 `VITE_BASE_URL=/art-supabase-pro/`。Dockerfile 用 `ARG` 默认值覆盖前两者中与容器部署不符的部分（见 6.2、6.3），因此**不要**在 `.dockerignore` 里排除 env 文件。
- 产物里只有 Supabase **publishable（anon）** 公钥，它本来就是公开信息；服务端密钥（service_role）绝不能进前端构建。
- 构建时会看到 Docker 的 lint 提示 `SecretsUsedInArgOrEnv ... (ARG "VITE_SUPABASE_KEY")`：这是按变量名里的 `KEY` 触发的通用告警，这里的值是已提交在 `.env` 且必然会被打包进 JS 的 publishable 公钥，**不是**服务端密钥，可忽略。
- 需要在运行期切换配置，只能改造成运行时注入（例如容器启动时生成 `window.__RUNTIME_CONFIG__`），当前架构不支持。

### 6.2 子路径部署坑点（最容易踩）

**现象**：访问首页白屏，控制台报 `/art-supabase-pro/assets/xxx.js` 404 或 `Failed to load module script`。

**根因**：`.env.production` 里的 `VITE_BASE_URL=/art-supabase-pro/` 是为 GitHub Pages（`docs/` 目录挂在仓库子路径）准备的。它会同时写进 `index.html` 的资源前缀和 vue-router 的 hash base（`src/router/index.ts` 的 `createWebHashHistory(import.meta.env.BASE_URL)`）。容器里 nginx 默认在 `/` 提供服务，资源却指向了 `/art-supabase-pro/`，必然 404。

**处理**：默认按根路径构建（Dockerfile 的 `ARG VITE_BASE_URL=/` 已覆盖）。确实要部署到子路径时，三处必须同步：

```bash
# 1) 构建参数    2) 产物落到子目录（改 Dockerfile 的 COPY 目标）
--build-arg VITE_BASE_URL=/art-supabase-pro/
COPY --from=builder /app/dist /usr/share/nginx/html/art-supabase-pro
# 3) 放开 nginx.conf 中注释掉的 location /art-supabase-pro/ 块
```

另外两点：

- 本项目路由是 **hash 模式**（`createWebHashHistory`），URL 形如 `/#/vehicle/manage`，深链刷新不需要服务端 History 回退；nginx 里的 `try_files ... /index.html` 是兜底，不是 hash 路由的必需项。
- `src/router/hashHistory.ts` 的 `normalizeHashRouterBase` 会把落在 base 之外的地址强制拉回 base，所以 base 与实际访问路径不一致时表现为「跳错地址」而不是 404。
- 想在本地先确认产物 base 是否正确：`pnpm serve`（`scripts/serve-built-app.ts` 会读取 index.html 里的 base 并按 base 提供文件），或直接 `grep -o 'src="[^"]*"' docs/index.html`。

### 6.3 `/api` 代理的真实边界（重要）

- **现状**：前端通过 `src/plugins/supabase.ts` 用 `VITE_SUPABASE_URL` 的**绝对地址**直连 Supabase，REST / Auth / Storage / Edge Function / Realtime 都**不经过容器**。nginx 的 `/api` 反代只对同源 `/api/**` 请求生效。
- **反代已覆盖的路径**：`/api/rest/v1/**`、`/api/auth/v1/**`、`/api/storage/v1/**`、`/api/functions/v1/**`、`/api/realtime/v1/**`（含 WebSocket Upgrade 透传）。它适用于自建网关/后端，或在构建期把 axios 层基址改成 `/api`（`src/utils/http/index.ts` 的 `baseURL` 取自 `VITE_API_URL`）：
  ```bash
  docker build --build-arg VITE_API_URL=/api -t art-supabase-pro:1.0.0 .
  ```
  注意当前代码里 axios 层只用于拉取 `${BASE_URL}data/pca-code.json`，`VITE_API_URL` 在 Supabase 模式下几乎是空配置。
- **不要把 `VITE_SUPABASE_URL` 改成 `/api` 或其它相对地址**，会让平台「全部租户」读写范围静默失效：
  - `src/utils/tenant-scope-context.ts` 的 `normalizePlatformTenantReadUrl` 用 `new URL(requestUrl)` 解析（相对地址会抛错并被 catch 吞掉，租户过滤不再归一化）；
  - 同文件 `shouldAttachTenantScopeHeader` 要求 pathname 以 `/rest/v1` 开头，`/api/rest/v1` 不匹配，tenant-scope 请求头不再注入；
  - `src/api/auth.ts` 用 `new URL('/functions/v1/oauth-provider-bridge/feishu/qr-prepare', projectUrl)` 生成飞书扫码地址，相对基址会直接抛错。
- 因此 `/api` 反代定位为「同源网关入口」，而不是让前端直连 Supabase 的替代方案。若将来要统一走同源网关（隐藏项目 ref、避免跨域），需要把 Supabase 基址改成绝对的同源前缀（例如 `https://<域名>/sb`）**并同步修改上述前缀判断逻辑**，属于代码改动，需单独评估。

### 6.4 登录 / OAuth 回调地址

直连 Supabase 时，浏览器用**部署域名**完成 PKCE 回调。容器化后域名/端口通常变了，必须在 Supabase Dashboard → Authentication → URL Configuration 里把 Site URL 与 Redirect URLs 加上实际访问地址（如 `http://192.168.1.10:8080`、`https://art.example.com`），否则表现为回调后停在登录页或提示重定向无效。前端用的是 `flowType: 'pkce'` + `detectSessionInUrl`，与 hash 路由共存是刻意设计，不需要改。

### 6.5 DNS / resolver（上游解析方式与代价）

`nginx.conf` 里 `/api` 的上游写成**静态地址**（`proxy_pass https://nvzlwcutsqptngyqfzqs.supabase.co/`），由 nginx 在启动时解析一次。这是实测后选定的方案：

- 好处：Docker Desktop（Windows/macOS）、Linux 引擎、K8s、裸机**都不需要额外配置 DNS**。
- 代价：启动时必须能解析该域名，否则 nginx 直接退出（实测报 `[emerg] host not found in upstream "nvzlwcutsqptngyqfzqs.supabase.co"`，容器 `exit 1`）。因此启动命令要带 restart 策略 —— compose 已配 `restart: unless-stopped`，`docker run` 请加 `--restart unless-stopped`，DNS 恢复后由重启自愈。
- 上游 IP 在容器生命周期内被固定；Supabase 侧更换 IP 时执行 `docker restart art-supabase-pro`（或容器内 `nginx -s reload`）重新解析。

如果更需要「启动不依赖 DNS」的请求时解析，就改成变量形式并显式指定 resolver：

```nginx
set $supabase_origin "https://nvzlwcutsqptngyqfzqs.supabase.co";
resolver 127.0.0.11 valid=30s ipv6=off;   # 必须按环境改成实际 DNS
proxy_pass $supabase_origin;
```

但要注意两个实测结论，否则会踩 502：

- **`127.0.0.11` 只在 Linux 引擎的 Docker 网络里可用**。Docker Desktop 容器的 `/etc/resolv.conf` 指向的是 `192.168.65.7`，硬编码 `127.0.0.11` 时 nginx 报 `recv() failed (111: Connection refused) while resolving, resolver: 127.0.0.11:53`，5s 后 502；K8s 用 kube-dns / CoreDNS 的 ClusterIP，裸机用宿主的 DNS。
- **`resolver` 写多个地址不会对同一次查询做故障转移**（实测第一个地址不可用就直接超时 502），所以不能靠 `resolver 127.0.0.11 192.168.65.7` 兜底。

Docker 内置 DNS 不可用时 `/api` 反代返回 502，但**静态托管不受影响**（变量方案下 nginx 仍能正常启动）。

### 6.6 发版与缓存策略

- `index.html` 不缓存（`Cache-Control: no-cache`），带 hash 的 `assets/**` 缓存 1 年 immutable：发版后刷新即生效，不需要清缓存或 CDN。
- `vendor/**`、`wasm/**`、`data/**` 不带 hash，用 1 小时 + `ETag`/`Last-Modified` 协商：升级后最多 1 小时内可能命中旧副本，但会通过 304 校验。
- 构建默认开启压缩（`VITE_BUILD_COMPRESS=true` → 生成 `.gz`），nginx 用 `gzip_static` 直接命中预压缩文件；若前置了 CDN/网关，请确保透传 `Content-Encoding`。

### 6.7 上传体积与超时

- `client_max_body_size 50m` 只在请求经过 nginx 时生效（例如走 `/api` 上传）；当前附件直传 Supabase Storage，不受此限制。
- `/api` 已设置 `proxy_read_timeout 300s`、`proxy_buffering off`、`gzip off`，为 Realtime 长连接与 Edge Function 流式响应准备；同源大文件下载不要放在 `/api` 下。

### 6.8 安全说明

- 容器沿用官方 `nginx:alpine` 的运行方式（master 为 root，worker 为 nginx）。需要非 root/只读根文件系统时，改用 `nginxinc/nginx-unprivileged` 或追加 `--read-only --tmpfs /var/cache/nginx`。
- 未启用 CSP：应用存在内联脚本、`blob:` Worker 与 Monaco/wasm，需要先梳理资源来源再开启，避免误伤。已开启 `X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy`。
- 镜像内只有静态产物与 `nginx.conf`；安全边界在 Supabase RLS 与业务权限策略，不在镜像。

### 6.9 构建期依赖与命令对照

- Node ≥ 22（`package.json` 的 `engines`），镜像用 `node:24-alpine`（与本地开发一致）；Alpine 需要 `libstdc++`，因为 rolldown / lightningcss / esbuild 是原生二进制。lockfile 已包含 `linux-x64-musl` / `linux-arm64-musl` 变体，Alpine 与 arm64 均可安装。
- 包管理器是 pnpm（`packageManager: pnpm@11.9.0`，仓库只有 `pnpm-lock.yaml`）。**`npm build` 不是有效命令**（应为 `npm run build`），本仓库请用 `pnpm build`（= `vite build`）。
- 产物目录由 `VITE_OUT_DIR` 决定：本地默认 `docs`（用于 GitHub Pages），**镜像内改为 `dist`**，因此本地 `docs/` 与本方案互不影响。
- 依赖安装使用 `--frozen-lockfile`，不会改写 lockfile；升级依赖请在本地 `pnpm install` 后提交 lockfile。

## 7. 排障对照表

| 现象 | 原因与处理 |
| --- | --- |
| 首页白屏，控制台 `assets/...` 404 | base 与访问路径不一致，见 6.2 |
| 浏览器报 `Unexpected token '<'` | 缺失资源被回退成 `index.html`；本配置对 `/assets/**` 直接 404，可排除该路径 |
| `/api/**` 返回 502 | 上游域名写错、容器无法出网，或容器启动时 DNS 失败导致 nginx 已退出（`docker ps -a` 看状态）；见 6.5 |
| `/api/**` 返回 401 / 400 | 正常：Supabase 需要 `apikey` / `Authorization`，由前端注入 |
| 容器启动即退出，`docker ps -a` 显示 `Exited (1)` | 启动时 DNS 无法解析上游域名，见 6.5；补 `--restart unless-stopped` 让它自愈 |
| 登录 / 飞书扫码回调失败 | Supabase Redirect URLs 未登记容器域名，见 6.4 |
| 改了环境变量但页面没变 | 构建期变量未重新构建，见 6.1 |
| 构建过程 OOM / 被 kill | 提高 Docker 可用内存，或调整 Dockerfile 里的 `NODE_OPTIONS` |
| 页面缺少某个业务模块 | 子模块未初始化，`git submodule update --init --recursive` 后重建 |
