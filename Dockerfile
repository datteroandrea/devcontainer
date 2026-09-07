# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# All-in-one development container:
# Ubuntu 24.04 + Postgres + Redis + C/C++ + Rust + Java + Node (React/Next.js)
# + Python + Git, ready for VS Code Dev Containers.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=22
ARG GRADLE_VERSION=8.14.3
# Latest stable Supabase CLI at time of writing. Leave empty to install latest.
ARG SUPABASE_VERSION=2.116.0

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# 1. Base OS packages, C/C++ toolchain, Postgres, Redis, Java, Python, Git
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # basics
      ca-certificates curl wget gnupg2 lsb-release apt-transport-https \
      sudo git git-lfs openssh-client rsync less nano vim zsh tmux \
      unzip zip xz-utils jq htop procps file locales man-db \
      # C / C++ toolchain
      build-essential gcc g++ clang clang-format clangd lldb gdb valgrind \
      make cmake ninja-build pkg-config autoconf automake libtool \
      libssl-dev zlib1g-dev libffi-dev libbz2-dev libreadline-dev libsqlite3-dev \
      # PostgreSQL
      postgresql postgresql-contrib postgresql-client libpq-dev \
      # Redis
      redis-server redis-tools \
      # Java
      openjdk-21-jdk maven \
      # Python
      python3 python3-dev python3-pip python3-venv pipx \
  && rm -rf /var/lib/apt/lists/*

# Architecture-independent JAVA_HOME
RUN ln -sfn "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")" /usr/lib/jvm/current
ENV JAVA_HOME=/usr/lib/jvm/current
ENV PATH=$JAVA_HOME/bin:$PATH

# Gradle (apt version lags behind, so grab the official distribution)
RUN wget -q "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -O /tmp/gradle.zip \
 && unzip -q /tmp/gradle.zip -d /opt \
 && rm /tmp/gradle.zip \
 && ln -sfn "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle

# ---------------------------------------------------------------------------
# 2. Node.js (+ npm, pnpm, yarn via corepack) — this is what runs React/Next.js
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable \
 && npm install -g npm@latest typescript ts-node \
 && npm cache clean --force
ENV NEXT_TELEMETRY_DISABLED=1

# ---------------------------------------------------------------------------
# 3. Rust (system-wide so every user gets it)
# ---------------------------------------------------------------------------
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain stable; \
    rm /tmp/rustup-init.sh; \
    rustup component add rustfmt clippy rust-analyzer rust-src; \
    rustc --version; cargo --version; \
    chmod -R a+rw "$RUSTUP_HOME" "$CARGO_HOME"

# ---------------------------------------------------------------------------
# 4. Python extras (Ubuntu 24.04 marks the system Python as externally managed,
#    so install shared tooling explicitly and use venvs/uv for project deps)
# ---------------------------------------------------------------------------
RUN pip3 install --no-cache-dir --break-system-packages \
      uv virtualenv pipenv ruff black ipython

# ---------------------------------------------------------------------------
# 5. Docker CLI (no daemon) — `supabase start` launches containers, so the
#    dev container talks to the HOST daemon via the mounted socket.
# ---------------------------------------------------------------------------
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 6. Supabase CLI
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://raw.githubusercontent.com/supabase/cli/main/install -o /tmp/supabase-install.sh; \
    if [ -n "${SUPABASE_VERSION}" ]; then \
      SUPABASE_INSTALL_DIR=/usr/local/bin bash /tmp/supabase-install.sh \
        --version "${SUPABASE_VERSION}" --no-modify-path; \
    else \
      SUPABASE_INSTALL_DIR=/usr/local/bin bash /tmp/supabase-install.sh --no-modify-path; \
    fi; \
    rm /tmp/supabase-install.sh; \
    supabase --version

# Deno — the runtime behind Supabase Edge Functions (gives you local
# type-checking and LSP; the CLI still runs functions in its own container)
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) DENO_TARGET=x86_64-unknown-linux-gnu ;; \
      arm64) DENO_TARGET=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/denoland/deno/releases/latest/download/deno-${DENO_TARGET}.zip" -o /tmp/deno.zip; \
    unzip -q /tmp/deno.zip -d /usr/local/bin; \
    rm /tmp/deno.zip; \
    chmod +x /usr/local/bin/deno; \
    deno --version

# ---------------------------------------------------------------------------
# 7. Non-root user (VS Code connects as this user)
# ---------------------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd --gid "$USER_GID" "$USERNAME" 2>/dev/null || true; \
    useradd --uid "$USER_UID" --gid "$USER_GID" --create-home --shell /bin/bash "$USERNAME"; \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"; \
    chmod 0440 "/etc/sudoers.d/$USERNAME"

# ---------------------------------------------------------------------------
# 8. PostgreSQL config + a role/database matching the dev user
#    NOTE: trust auth and listening on all interfaces is fine for a local dev
#    container. Do not reuse this configuration anywhere reachable.
# ---------------------------------------------------------------------------
RUN set -eux; \
    PG_VERSION="$(ls /usr/lib/postgresql | sort -V | tail -n1)"; \
    CONF_DIR="/etc/postgresql/${PG_VERSION}/main"; \
    echo "listen_addresses = '*'"           >> "${CONF_DIR}/postgresql.conf"; \
    echo "host all all 0.0.0.0/0 trust"     >> "${CONF_DIR}/pg_hba.conf"; \
    echo "host all all ::/0 trust"          >> "${CONF_DIR}/pg_hba.conf"; \
    pg_ctlcluster "$PG_VERSION" main start; \
    su postgres -c "psql -c \"CREATE ROLE ${USERNAME} WITH LOGIN SUPERUSER PASSWORD '${USERNAME}';\""; \
    su postgres -c "createdb -O ${USERNAME} ${USERNAME}"; \
    su postgres -c "createdb -O ${USERNAME} devdb"; \
    pg_ctlcluster "$PG_VERSION" main stop

# ---------------------------------------------------------------------------
# 9. Redis config (bind on all interfaces inside the container)
# ---------------------------------------------------------------------------
RUN sed -i \
      -e 's/^bind .*/bind 0.0.0.0 -::1/' \
      -e 's/^protected-mode yes/protected-mode no/' \
      -e 's/^daemonize yes/daemonize no/' \
      /etc/redis/redis.conf

# ---------------------------------------------------------------------------
# 10. Workspace + entrypoint that boots Postgres and Redis
# ---------------------------------------------------------------------------
ENV DEV_USER=$USERNAME
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN mkdir -p /workspace && chown "$USER_UID:$USER_GID" /workspace
WORKDIR /workspace

# Git is happier with bind-mounted repos owned by a different host UID
RUN git config --system --add safe.directory '*'

# The Supabase stack runs on the HOST daemon, so reach it through the gateway
# rather than localhost. Run `supabase status` to get the anon/service keys.
ENV DATABASE_URL="postgresql://vscode:vscode@localhost:5432/devdb" \
    REDIS_URL="redis://localhost:6379" \
    SUPABASE_URL="http://host.docker.internal:54321" \
    SUPABASE_DB_URL="postgresql://postgres:postgres@host.docker.internal:54322/postgres" \
    SUPABASE_STUDIO_URL="http://host.docker.internal:54323"

EXPOSE 3000 3001 5173 8000 8080 5432 6379

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
