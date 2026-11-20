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
MARKER="$PGDATA/.hypergres-scram"
mkdir -p "$PGDATA"
set_role_password() {
  # $1 = password. Converges the postgres role to SCRAM via single-user
  # mode (no listener needed). Idempotent: safe to re-run on every restart.
  _pwq="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "SET password_encryption = 'scram-sha-256';\nALTER ROLE postgres WITH PASSWORD '%s';\n" "$_pwq" \
    | postgres --single -D "$PGDATA" postgres >/dev/null
}
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  # First start: a role password is mandatory. Hyperdrive reaches this
  # image over TCP (not localhost), and remote logins must never be
  # passwordless — so fail closed with a clear error instead of initdb'ing
  # a passwordless role.
  if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo 'hypergres: FATAL: refusing first start without POSTGRES_PASSWORD.' >&2
    echo 'hypergres: FATAL: Hyperdrive TCP clients need a postgres role password (SCRAM).' >&2
    echo 'hypergres: FATAL: re-run with -e POSTGRES_PASSWORD=<secret>.' >&2
    exit 1
  fi
  PWFILE="$(mktemp)"
  # Remove the password file even if initdb fails (trap disarmed after success).
  trap 'rm -f "$PWFILE"' EXIT
  printf '%s' "$POSTGRES_PASSWORD" > "$PWFILE"
  initdb -D "$PGDATA" --auth=scram-sha-256 --username=postgres --pwfile="$PWFILE"
  rm -f "$PWFILE"
  trap - EXIT
  touch "$MARKER"
elif [ -n "${POSTGRES_PASSWORD:-}" ]; then
  # Restart with a (possibly rotated) password: converge the role.
  set_role_password "$POSTGRES_PASSWORD"
  touch "$MARKER"
fi
# TLS is mandatory (Hyperdrive rejects non-TLS). Prefer an operator-mounted
# cert; otherwise mint a self-signed one. Fail closed: never boot ssl=off,
# and never silently clobber a half-mounted pair.
_have_crt=0; _have_key=0
[ -f "$PGDATA/server.crt" ] && _have_crt=1
[ -f "$PGDATA/server.key" ] && _have_key=1
if [ "$((_have_crt + _have_key))" -eq 1 ]; then
  echo 'hypergres: FATAL: half-mounted TLS pair in $PGDATA (have cert XOR key).' >&2
  echo 'hypergres: FATAL: mount BOTH server.crt and server.key, or NEITHER (self-signed).' >&2
  exit 1
fi
if [ "$_have_crt" -eq 0 ]; then
  openssl req -new -x509 -days 365 -nodes -subj "/CN=hypergres" \
    -out "$PGDATA/server.crt" -keyout "$PGDATA/server.key"
  chmod 600 "$PGDATA/server.key"
fi
# Hyperdrive arrives over TCP via the gateway, but stock initdb pg_hba
# allows localhost only. Permit TLS remotes with SCRAM, idempotently
# (append only if absent — restarts must not duplicate the line). The line
# goes AFTER stock localhost lines on purpose: first pg_hba match wins, so
# local logins keep their initdb method while non-localhost TLS must SCRAM.
if ! grep -qxF 'hostssl all all 0.0.0.0/0 scram-sha-256' "$PGDATA/pg_hba.conf" 2>/dev/null; then
  printf '%s\n' 'hostssl all all 0.0.0.0/0 scram-sha-256' >> "$PGDATA/pg_hba.conf"
fi
# Fail closed: never serve (remote) clients without a configured role password.
if [ ! -f "$MARKER" ]; then
  echo 'hypergres: FATAL: no postgres role password configured for this data dir.' >&2
  echo 'hypergres: FATAL: re-run with -e POSTGRES_PASSWORD=<secret> to set it.' >&2
  exit 1
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
  -c log_connections=on \
  -c password_encryption=scram-sha-256
# FRAGMENT-END
