#!/bin/sh
# DERIVED FILE — DO NOT EDIT BY HAND.
# Single source of truth: the `shell-fragment` entrypoint in apko.yaml
# (that is what actually boots in the image). This file is a verbatim copy
# of that fragment, for inspection and mount-based use.
# scripts/verify-build.sh diffs the FRAGMENT block below against apko.yaml
# and fails on any drift.
# FRAGMENT-BEGIN
set -eu
PGDATA=${PGDATA:-/var/lib/postgresql/data}
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
# TLS is mandatory (Hyperdrive rejects non-TLS). Prefer an operator-mounted
# cert; otherwise mint a self-signed one. Fail closed: never boot ssl=off.
if [ ! -f "$PGDATA/server.crt" ] || [ ! -f "$PGDATA/server.key" ]; then
  openssl req -new -x509 -days 365 -nodes -subj "/CN=hypergres" \
    -out "$PGDATA/server.crt" -keyout "$PGDATA/server.key"
  chmod 600 "$PGDATA/server.key"
fi
# Mirrors postgresql.conf values verbatim.
exec postgres -D "$PGDATA" \
  -c listen_addresses='*' \
  -c ssl=on \
  -c ssl_cert_file="$PGDATA/server.crt" \
  -c ssl_key_file="$PGDATA/server.key" \
  -c max_connections=100 \
  -c shared_buffers=128MB \
  -c statement_timeout=30s \
  -c idle_in_transaction_session_timeout=60s \
  -c log_connections=on
# FRAGMENT-END
