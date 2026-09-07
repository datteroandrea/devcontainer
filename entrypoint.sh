#!/usr/bin/env bash
set -euo pipefail

PG_VERSION="$(ls /usr/lib/postgresql | sort -V | tail -n1)"

# --- PostgreSQL -------------------------------------------------------------
# If a fresh empty volume was mounted over the data directory, recreate the
# cluster so the container still comes up.
if [ ! -d "/var/lib/postgresql/${PG_VERSION}/main" ]; then
  echo "[entrypoint] No Postgres cluster found, creating one..."
  chown -R postgres:postgres /var/lib/postgresql
  pg_createcluster "$PG_VERSION" main
fi

chown -R postgres:postgres "/var/lib/postgresql/${PG_VERSION}" || true

if ! pg_isready -q 2>/dev/null; then
  echo "[entrypoint] Starting PostgreSQL ${PG_VERSION}..."
  pg_ctlcluster "$PG_VERSION" main start || true
fi

# --- Redis ------------------------------------------------------------------
if ! redis-cli ping >/dev/null 2>&1; then
  echo "[entrypoint] Starting Redis..."
  mkdir -p /var/lib/redis /var/log/redis /var/run/redis
  chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis
  redis-server /etc/redis/redis.conf --daemonize yes
fi

# --- Docker socket ----------------------------------------------------------
# The socket's group ID comes from the host and varies per machine, so grant
# the dev user access to whatever group actually owns it.
DEV_USER="${DEV_USER:-vscode}"
if [ -S /var/run/docker.sock ]; then
  SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"
  if [ "$SOCK_GID" = "0" ]; then
    # Docker Desktop mounts a root-owned socket; sudo covers this case.
    chmod 666 /var/run/docker.sock || true
  else
    if ! getent group "$SOCK_GID" >/dev/null; then
      groupadd --gid "$SOCK_GID" docker-host
    fi
    SOCK_GROUP="$(getent group "$SOCK_GID" | cut -d: -f1)"
    usermod -aG "$SOCK_GROUP" "$DEV_USER"
  fi
  echo "[entrypoint] Docker socket ready (gid ${SOCK_GID})"
else
  echo "[entrypoint] WARNING: /var/run/docker.sock not mounted — 'supabase start' will fail."
fi

echo "[entrypoint] Postgres: $(pg_isready 2>&1 || true)"
echo "[entrypoint] Redis:    $(redis-cli ping 2>&1 || true)"

exec "$@"
