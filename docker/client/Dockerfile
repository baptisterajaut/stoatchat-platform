# Stoatchat web client (for-web) — self-contained build
#
# Builds the SolidJS client from https://github.com/stoatchat/for-web
# and serves it via nginx with runtime environment injection.
#
# Once https://github.com/stoatchat/for-web/pull/522 lands, an official
# ghcr.io/stoatchat/client image will exist. It won't include runtime
# env replacement though, so this Dockerfile remains useful for
# self-hosting scenarios where the API URL isn't known at build time.
#
# Usage:
#   docker build -t stoatchat-web docker/client/
#   docker build --build-arg STOATCHAT_WEB_REF=v1.0.0 -t stoatchat-web docker/client/
#
# Required env at runtime:
#   REVOLT_PUBLIC_URL   Base API URL (e.g. https://stoatchat.example.com/api)
#
# Optional env overrides:
#   VITE_WS_URL         WebSocket URL (derived from REVOLT_PUBLIC_URL by default)
#   VITE_MEDIA_URL      File server URL (default: .../autumn)
#   VITE_PROXY_URL      Proxy/embed URL (default: .../january)
#   VITE_HCAPTCHA_SITEKEY

# Build stage
FROM node:22-bookworm-slim AS builder

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN corepack enable && corepack prepare pnpm@10.10.0 --activate

WORKDIR /app

ARG STOATCHAT_WEB_REPO=https://github.com/stoatchat/for-web
ARG STOATCHAT_WEB_REF=main
ARG STOATCHAT_ASSETS_REPO=https://github.com/stoatchat/assets.git
ARG CACHE_BUST=1
RUN git clone --branch ${STOATCHAT_WEB_REF} --recurse-submodules \
    ${STOATCHAT_WEB_REPO} .
# Assets submodule uses SSH in .gitmodules; clone via HTTPS separately
RUN rm -rf packages/client/assets && \
    git clone --depth 1 ${STOATCHAT_ASSETS_REPO} packages/client/assets

# Placeholders replaced at runtime by entrypoint.sh
ENV VITE_API_URL=__VITE_API_URL__
ENV VITE_WS_URL=__VITE_WS_URL__
ENV VITE_MEDIA_URL=__VITE_MEDIA_URL__
ENV VITE_PROXY_URL=__VITE_PROXY_URL__
ENV VITE_HCAPTCHA_SITEKEY=__VITE_HCAPTCHA_SITEKEY__
ENV NODE_OPTIONS="--max-old-space-size=4096"

RUN pnpm install --frozen-lockfile
RUN pnpm --filter @lingui-solid/babel-plugin-lingui-macro build && \
    pnpm --filter @lingui-solid/babel-plugin-extract-messages build
RUN pnpm --filter solid-livekit-components build
RUN pnpm --filter stoat.js build
RUN pnpm --filter client exec node scripts/copyAssets.mjs
RUN pnpm --filter client exec lingui compile --typescript
RUN pnpm --filter client exec vite build

# Runtime stage
FROM nginx:alpine

COPY --from=builder /app/packages/client/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 5000
ENTRYPOINT ["/docker-entrypoint.sh"]
