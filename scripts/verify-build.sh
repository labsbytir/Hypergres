#!/bin/sh
# Task 1 verify: build the apko image, load it into podman, boot it, and assert
# pg_isready + version + application_name passthrough.
set -eu

TAG="${TAG:-hypergres:test}"
NAME="${NAME:-hypergres-verify}"
ARCH="${ARCH:-host}"
# Role password for the SCRAM-only image: passed as POSTGRES_PASSWORD on first
# start, as PGPASSWORD to local psql probes. Override per-run if needed.
PGPASSWORD="${PGPASSWORD:-hypergres-verify-pw}"

cleanup() { /opt/podman/bin/podman rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

wait_ready() {
  # $1 = container name. Poll pg_isready (SCRAM needs PGPASSWORD).
  for i in $(seq 1 60); do
    if /opt/podman/bin/podman exec --env "PGPASSWORD=$PGPASSWORD" "$1" pg_isready -U postgres >/dev/null 2>&1; then
      return 0
    fi
    if [ "$i" -eq 60 ]; then
      echo "FAIL: pg_isready never ok for $1" >&2
      /opt/podman/bin/podman logs "$1" | tail -20 >&2 || true
      return 1
    fi
    sleep 1
  done
}

echo "==> entrypoint parity (apko.yaml shell-fragment vs entrypoint.sh)"
FRAG="$(mktemp)"; DERIVED="$(mktemp)"
awk '/shell-fragment: \|/{f=1;next} f&&/^[^ ]/{f=0} f' apko.yaml | sed 's/^    //' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$FRAG"
sed -n '/^# FRAGMENT-BEGIN$/,/^# FRAGMENT-END$/p' entrypoint.sh | sed '1d;$d' > "$DERIVED"
if ! diff -u "$FRAG" "$DERIVED"; then
  echo "FAIL: entrypoint.sh drifted from apko.yaml shell-fragment" >&2
  exit 1
fi
rm -f "$FRAG" "$DERIVED"
echo "entrypoint parity ok"

echo "==> apko build $TAG"
# NOTE: apko v1.5.x requires an explicit output path (older versions defaulted
# to <tag>.tar, as in the original Task 1 brief command).
OUT="hypergres-build.tar"
rm -f "$OUT" "$TAG"-*.tar hypergres-*.tar
# Pinned Wolfi package set (finding 2): regenerate with
# `apko lock apko.yaml --output apko.lock.json` after any apko.yaml change.
apko build apko.yaml "$TAG" "$OUT" --sbom=false --arch="$ARCH" --lockfile apko.lock.json

TARBALL="$OUT"
echo "==> /opt/podman/bin/podman load < $TARBALL"
IMAGE="$(/opt/podman/bin/podman load < "$TARBALL" | sed -n 's/^Loaded image: //p' | tail -1)"
if [ -z "${IMAGE:-}" ]; then
  echo "FAIL: podman load produced no image" >&2
  exit 1
fi
echo "loaded: $IMAGE"

/opt/podman/bin/podman rm -f "$NAME" >/dev/null 2>&1 || true
echo "==> podman run $NAME (POSTGRES_PASSWORD set — image refuses passwordless boot)"
/opt/podman/bin/podman run -d --name "$NAME" -e POSTGRES_PASSWORD="$PGPASSWORD" -p 5433:5432 "$IMAGE" >/dev/null

echo "==> waiting for pg_isready (60s)"
wait_ready "$NAME" || exit 1
echo "pg_isready ok"

echo "==> SELECT version()"
/opt/podman/bin/podman exec --env "PGPASSWORD=$PGPASSWORD" "$NAME" psql -U postgres -h 127.0.0.1 -tAc "SELECT version();" | grep -q "PostgreSQL 17" \
  || { echo "FAIL: not PostgreSQL 17" >&2; exit 1; }
echo "version ok (PostgreSQL 17)"

echo "==> application_name passthrough"
/opt/podman/bin/podman exec --env "PGPASSWORD=$PGPASSWORD" "$NAME" psql "host=127.0.0.1 user=postgres application_name=hypergres-verify dbname=postgres" \
  -tAc "SHOW application_name;" | grep -q "hypergres-verify" \
  || { echo "FAIL: application_name not passed through" >&2; exit 1; }
echo "application_name ok"

echo "==> config values (brief Step 2)"
check_show() {
  _got="$(/opt/podman/bin/podman exec --env "PGPASSWORD=$PGPASSWORD" "$NAME" psql -U postgres -h 127.0.0.1 -tAc "SHOW $1;" | tr -d '[:space:]')"
  if [ "$_got" != "$2" ]; then
    echo "FAIL: SHOW $1 = '$_got', want '$2'" >&2
    exit 1
  fi
  echo "$1=$_got ok"
}
check_show ssl on
check_show max_connections 100
check_show shared_buffers 128MB
check_show statement_timeout 30s
check_show idle_in_transaction_session_timeout 1min
check_show log_connections on
check_show password_encryption scram-sha-256

echo "==> non-root uid 65532"
_uid="$(/opt/podman/bin/podman exec "$NAME" id -u)"
if [ "$_uid" != "65532" ]; then
  echo "FAIL: container uid is $_uid, want 65532" >&2
  exit 1
fi
echo "uid=65532 ok"

echo "==> fail-closed without POSTGRES_PASSWORD (expect exit 1 + FATAL)"
FAILNAME="$NAME-nopw"
/opt/podman/bin/podman rm -f "$FAILNAME" >/dev/null 2>&1 || true
/opt/podman/bin/podman run -d --name "$FAILNAME" "$IMAGE" >/dev/null
_code="$(/opt/podman/bin/podman wait "$FAILNAME" 2>/dev/null || echo wait-failed)"
if [ "$_code" != "1" ]; then
  echo "FAIL: passwordless boot exited '$_code', want '1'" >&2
  /opt/podman/bin/podman rm -f "$FAILNAME" >/dev/null 2>&1 || true
  exit 1
fi
/opt/podman/bin/podman logs "$FAILNAME" 2>&1 | grep -q 'FATAL: refusing first start without POSTGRES_PASSWORD' \
  || { echo "FAIL: no clear FATAL in passwordless-boot logs" >&2; exit 1; }
/opt/podman/bin/podman rm -f "$FAILNAME" >/dev/null
echo "fail-closed ok"

echo "==> restart idempotency (single hostssl line, server back)"
/opt/podman/bin/podman restart "$NAME" >/dev/null
wait_ready "$NAME" || exit 1
_n="$(/opt/podman/bin/podman exec "$NAME" grep -c -xF 'hostssl all all 0.0.0.0/0 scram-sha-256' /var/lib/postgresql/data/pg_hba.conf | tr -d '[:space:]')"
if [ "$_n" != "1" ]; then
  echo "FAIL: hostssl line present $_n times, want exactly 1" >&2
  exit 1
fi
echo "restart idempotency ok"

/opt/podman/bin/podman rm -f "$NAME" >/dev/null
echo "PASS"
