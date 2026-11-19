#!/bin/sh
# Hypergres entrypoint: initdb on first start, then exec postgres as uid 65532.
set -eu

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
CONF="${CONF:-/etc/postgresql/postgresql.conf}"

mkdir -p "$PGDATA"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  if [ -n "${POSTGRES_PASSWORD:-}" ]; then
    PWFILE="$(mktemp)"
    printf '%s' "$POSTGRES_PASSWORD" > "$PWFILE"
    initdb -D "$PGDATA" --auth=scram-sha-256 --username=postgres --pwfile="$PWFILE"
    rm -f "$PWFILE"
  else
    initdb -D "$PGDATA" --auth=trust --username=postgres
  fi
fi

# ssl=on needs a cert/key. Task 2 mounts real certs; without them (and without
# openssl to mint a self-signed pair) fall back to ssl=off so the image still boots.
SSL_ARGS=""
if grep -q "^ssl = on" "$CONF" 2>/dev/null; then
  if [ -f "$PGDATA/server.crt" ] && [ -f "$PGDATA/server.key" ]; then
    SSL_ARGS="-c ssl_cert_file=$PGDATA/server.crt -c ssl_key_file=$PGDATA/server.key"
  elif command -v openssl >/dev/null 2>&1; then
    openssl req -new -x509 -days 365 -nodes -subj "/CN=hypergres" \
      -out "$PGDATA/server.crt" -keyout "$PGDATA/server.key" 2>/dev/null
    chmod 600 "$PGDATA/server.key"
    SSL_ARGS="-c ssl_cert_file=$PGDATA/server.crt -c ssl_key_file=$PGDATA/server.key"
  else
    echo "hypergres: no TLS cert and no openssl; starting with ssl=off" >&2
    SSL_ARGS="-c ssl=off"
  fi
fi

# shellcheck disable=SC2086
exec postgres -D "$PGDATA" -c "config_file=$CONF" $SSL_ARGS
