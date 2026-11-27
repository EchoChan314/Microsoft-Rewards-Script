# syntax=docker/dockerfile:1
###############################################################################
# Stage 1: Builder
###############################################################################
FROM node:24-slim AS builder

WORKDIR /usr/src/microsoft-rewards-script

# Copy package files
COPY package.json package-lock.json tsconfig.json ./

# Install all dependencies required to build the script (npm cache is a BuildKit
# cache mount, it never ends up in the layer)
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts

# Copy source and build
COPY . .
RUN npm run build

###############################################################################
# Stage 2: Production dependencies
###############################################################################
# Separate stage so the runtime image only ever installs production deps once
FROM node:24-slim AS prod-deps

WORKDIR /usr/src/microsoft-rewards-script

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts

###############################################################################
# Stage 3: Runtime
###############################################################################
FROM node:24-slim AS runtime

WORKDIR /usr/src/microsoft-rewards-script

# Set production environment variables
ENV NODE_ENV=production \
    TZ=UTC \
    PLAYWRIGHT_BROWSERS_PATH=0 \
    FORCE_HEADLESS=1 \
    NODE_OPTIONS=--disable-warning=ExperimentalWarning

# Install only the system libraries required by the Chromium headless shell,
# plus jq (config generation/patching) and gettext-base (envsubst).
# Keep this list explicit instead of using `patchright install --with-deps`,
# which would reinstall an overlapping dependency set (~200MB) on every build.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cron \
    gettext-base \
    jq \
    tzdata \
    ca-certificates \
    libglib2.0-0 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libasound2 \
    libflac12 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libdrm2 \
    libgbm1 \
    libdav1d6 \
    libx11-6 \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    libdouble-conversion3 \
    libcups2 \
    libxkbcommon0 \
    libxshmfence1 \
    fonts-liberation \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Copy compiled application and dependencies from build stages
COPY --from=builder /usr/src/microsoft-rewards-script/dist ./dist
COPY --from=builder /usr/src/microsoft-rewards-script/package*.json ./
COPY --from=prod-deps /usr/src/microsoft-rewards-script/node_modules ./node_modules

# Install patchright's stealth-patched Chromium headless shell.
# The container is headless-only so the full browser isn't needed.
# 二进制走 npmmirror 国内镜像（cdn.playwright.dev 国内直连极慢，2026-11 实测 114MB 约 10 分钟）
ENV PLAYWRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright
RUN set -eux; \
    npx patchright install --only-shell chromium; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Copy config example into the image so entrypoint can use it as a fallback
# when the user hasn't mounted their own config.json
COPY config.example.json ./config.example.json

# config.json is managed via the ./config bind mount (compose.yaml mounts
# ./config to /usr/src/microsoft-rewards-script/config). On first run the
# entrypoint generates config/config.json from this example if none exists,
# then symlinks it to the project root where the script expects it.
# Accounts come from ACCOUNT_N_* env vars, so no accounts.json is needed.

# Copy runtime scripts with proper permissions from the start
COPY --chmod=755 scripts/docker/run_daily.sh ./scripts/docker/run_daily.sh
COPY --chmod=755 scripts/docker/healthcheck.sh ./scripts/docker/healthcheck.sh
COPY --chmod=755 scripts/api/ ./scripts/api/
COPY --chmod=644 scripts/env.js ./scripts/env.js
COPY --chmod=644 scripts/package.json ./scripts/package.json
COPY --chmod=644 src/crontab.template /etc/cron.d/microsoft-rewards-cron.template
COPY --chmod=755 scripts/docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# Entrypoint handles TZ, accounts/config generation, initial run toggle,
# cron templating & launch, or API server startup when API_MODE=true
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sh", "-c", "echo 'Container started; cron is running.'"]
