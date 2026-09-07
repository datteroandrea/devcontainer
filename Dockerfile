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
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal \
        --default-toolchain stable \
        --component rustfmt clippy rust-analyzer rust-src \
 && chmod -R a+rw "$RUSTUP_HOME" "$CARGO_HOME"

# ---------------------------------------------------------------------------
# 4. Python extras (Ubuntu 24.04 marks the system Python as externally managed,
#    so install shared tooling explicitly and use venvs/uv for project deps)
# ---------------------------------------------------------------------------
RUN pip3 install --no-cache-dir --break-system-packages \
      uv virtualenv pipenv ruff black ipython

# ---------------------------------------------------------------------------
# 5. Non-root user (VS Code connects as this user)
# ---------------------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd --gid "$USER_GID" "$USERNAME" 2>/dev/null || true; \
    useradd --uid "$USER_UID" --gid "$USER_GID" --create-home --shell /bin/bash "$USERNAME"; \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"; \
    chmod 0440 "/etc/sudoers.d/$USERNAME"

# ---------------------------------------------------------------------------
# 6. PostgreSQL config + a role/database matching the dev user
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
# 7. Redis config (bind on all interfaces inside the container)
# ---------------------------------------------------------------------------
RUN sed -i \
      -e 's/^bind .*/bind 0.0.0.0 -::1/' \
      -e 's/^protected-mode yes/protected-mode no/' \
      -e 's/^daemonize yes/daemonize no/' \
      /etc/redis/redis.conf

# ---------------------------------------------------------------------------
# 8. Workspace + entrypoint that boots Postgres and Redis
# ---------------------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN mkdir -p /workspace && chown "$USER_UID:$USER_GID" /workspace
WORKDIR /workspace

# Git is happier with bind-mounted repos owned by a different host UID
RUN git config --system --add safe.directory '*'

ENV DATABASE_URL="postgresql://vscode:vscode@localhost:5432/devdb" \
    REDIS_URL="redis://localhost:6379"

EXPOSE 3000 3001 5173 8000 8080 5432 6379

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
