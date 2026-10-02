# syntax=docker/dockerfile:1
#
# 程管家 art-supabase-pro —— 生产镜像（多阶段构建）
#   构建阶段：node:alpine + pnpm 执行 `vite build`，产出静态站点
#   运行阶段：nginx:alpine，静态托管 + History 路由回退 + /api 反向代理到 Supabase
#
# 构建：docker build -t art-supabase-pro:1.0.0 .
# 编排：docker compose up -d --build
# 完整命令与注意事项见 DOCKER.md

# ------------------------------ 构建阶段 ------------------------------
FROM node:24-alpine AS builder

WORKDIR /app

# vite 8 的 rolldown / lightningcss / esbuild 都是原生二进制，Alpine(musl) 需要 libstdc++
RUN apk add --no-cache libstdc++ \
  && npm install -g pnpm@11.9.0 --no-fund --no-audit

# 依赖清单先入层：业务代码改动时可复用依赖安装缓存
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .

# ---------- 构建期环境变量 ----------
# Vite 的 loadEnv 会用进程环境覆盖 .env / .env.production 中的同名变量，
# 因此这里的构建参数优先级最高。默认值 / 会覆盖 .env.production 里的
# VITE_BASE_URL=/art-supabase-pro/（子路径配置），因为容器默认在根路径提供服务。
ARG VITE_BASE_URL=/
ARG VITE_OUT_DIR=dist
ARG VITE_BUILD_COMPRESS=true
ARG VITE_SUPABASE_URL=https://nvzlwcutsqptngyqfzqs.supabase.co
# publishable(anon) 公钥本身就会打包进前端产物，不是服务端密钥
ARG VITE_SUPABASE_KEY=sb_publishable_QG4vqGLvkbaR7j5pD7woeA_kF_2ORTC
ENV VITE_BASE_URL=$VITE_BASE_URL \
  VITE_OUT_DIR=$VITE_OUT_DIR \
  VITE_BUILD_COMPRESS=$VITE_BUILD_COMPRESS \
  VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
  VITE_SUPABASE_KEY=$VITE_SUPABASE_KEY \
  NODE_OPTIONS=--max-old-space-size=4096

RUN pnpm build

# ------------------------------ 运行阶段 ------------------------------
FROM nginx:alpine AS runtime

LABEL org.opencontainers.image.title="art-supabase-pro" \
  org.opencontainers.image.description="程管家（Vue3 + Vite + Supabase），nginx 静态托管" \
  org.opencontainers.image.source="https://gitee.com/hz24931233/art-supabase-pro"

# 覆盖默认站点配置：History 回退 + /api 反代，详见 nginx.conf
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
