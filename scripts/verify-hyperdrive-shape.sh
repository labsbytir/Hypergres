#!/bin/sh
# Task 2 verify: disposable Hyperdrive-shape check.
# Boots the Task 1 image, applies the Harvy operational migration (read-only,
# never copied into this repo), and proves: trigger rejects revision mutation,
# and two fresh per-request TLS clients (cached/no-cache binding shape) read rows.
# Self-signed container cert is expected here, so checks use sslmode=require
# (NOT verify-full). Trust auth matches the Task 1 entrypoint default.
set -eu

PODMAN="${PODMAN:-/opt/podman/bin/podman}"
TAG="${TAG:-hypergres:test}"
NAME="${NAME:-hypergres-shape}"
PORT="${PORT:-5434}"
MIGRATION="${MIGRATION:-/Users/pen/Documents/Harvy/harvy/packages/db/postgres/migrations/0001_operational.sql}"
PGSSLMODE=require
export PGSSLMODE PORT

if [ ! -f "$MIGRATION" ]; then
  echo "FAIL: migration not found at $MIGRATION (set MIGRATION=...)" >&2
  exit 1
fi

cleanup() { "$PODMAN" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

resolve_image() {
  if "$PODMAN" image exists "$TAG" 2>/dev/null; then printf '%s' "$TAG"; return 0; fi
  _found="$("$PODMAN" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep 'hypergres:' | head -1 || true)"
  if [ -n "${_found:-}" ]; then printf '%s' "$_found"; return 0; fi
  return 1
}

if IMAGE="$(resolve_image)"; then
  echo "==> using image $IMAGE"
else
  echo "==> no hypergres image — building from apko.yaml (Task 1)"
  OUT="hypergres-shape-build.tar"
  rm -f "$OUT"
  apko build apko.yaml "$TAG" "$OUT" --sbom=false --arch=host --lockfile apko.lock.json
  IMAGE="$("$PODMAN" load < "$OUT" | sed -n 's/^Loaded image: //p' | tail -1)"
  [ -n "$IMAGE" ] || { echo "FAIL: podman load produced no image" >&2; exit 1; }
  echo "loaded: $IMAGE"
fi

"$PODMAN" rm -f "$NAME" >/dev/null 2>&1 || true
echo "==> podman run $NAME (host $PORT -> container 5432)"
"$PODMAN" run -d --name "$NAME" -p "$PORT":5432 "$IMAGE" >/dev/null

echo "==> waiting for pg_isready (60s)"
for i in $(seq 1 60); do
  if "$PODMAN" exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  if [ "$i" -eq 60 ]; then
    echo "FAIL: pg_isready never ok" >&2
    "$PODMAN" logs "$NAME" | tail -20 >&2 || true
    exit 1
  fi
  sleep 1
done
echo "pg_isready ok"

echo "==> ssl=on (Hyperdrive rejects non-TLS)"
_ssl="$("$PODMAN" exec "$NAME" psql -U postgres -h 127.0.0.1 -tAc 'SHOW ssl;' | tr -d '[:space:]')"
[ "$_ssl" = "on" ] || { echo "FAIL: ssl is '$_ssl'" >&2; exit 1; }
echo "ssl=on ok"

# Disposable-harness setup (container runtime only, not image config): stock
# initdb pg_hba allows localhost only, but host-side clients arrive via the
# gateway IP. Allow TLS remotes here; production must solve this in the image
# (entrypoint pg_hba + scram, real cert) — see Task 2 report.
echo "==> allow host-side TLS clients (disposable pg_hba + reload)"
"$PODMAN" exec "$NAME" sh -c "printf '%s\n' 'hostssl all all all trust' >> /var/lib/postgresql/data/pg_hba.conf" >/dev/null
"$PODMAN" exec "$NAME" psql -U postgres -h 127.0.0.1 -tAc 'SELECT pg_reload_conf();' >/dev/null
echo "pg_hba ok"

echo "==> apply $MIGRATION"
"$PODMAN" exec -i "$NAME" psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 < "$MIGRATION" >/dev/null
echo "migration ok"

echo "==> seed entity + revision"
"$PODMAN" exec "$NAME" psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 \
  -c "INSERT INTO entities(id,tenant_id,type,schema_id) VALUES ('11111111-1111-4111-8111-111111111111','tenant-a','probe','probe/v1');" \
  -c "INSERT INTO record_revisions(id,tenant_id,record_id,schema_id,schema_version,actor,source,data,recorded_at) VALUES ('22222222-2222-4222-8222-222222222222','tenant-a','11111111-1111-4111-8111-111111111111','probe/v1','v1','actor-1','probe','{\"hello\":\"world\"}',now());" \
  >/dev/null
echo "seed ok"

echo "==> UPDATE record_revisions must fail (append-only trigger)"
if _err="$("$PODMAN" exec "$NAME" psql -U postgres -h 127.0.0.1 \
    -c "UPDATE record_revisions SET data='{}' WHERE id='22222222-2222-4222-8222-222222222222';" 2>&1)"; then
  echo "FAIL: UPDATE succeeded, trigger did not reject" >&2
  exit 1
fi
printf '%s\n' "$_err" | grep -q 'append-only' || { echo "FAIL: unexpected error: $_err" >&2; exit 1; }
echo "trigger ok (UPDATE rejected: record_revisions is append-only)"

echo "==> per-request node pg clients x2 (cached / no-cache bindings)"
command -v node >/dev/null || { echo "FAIL: node not found" >&2; exit 1; }
WORK="$(mktemp -d)"
if ! node -e "require('pg')" >/dev/null 2>&1; then
  echo "-- pg module missing, installing into disposable $WORK"
  command -v npm >/dev/null || { echo "FAIL: npm not found" >&2; exit 1; }
  (cd "$WORK" && npm install --no-save --no-audit --no-fund pg >/dev/null 2>&1) \
    || { echo "FAIL: npm install pg" >&2; exit 1; }
  export NODE_PATH="$WORK/node_modules"
fi
node -e "
const {Client} = require('pg');
(async () => {
  for (const app of ['hyperdrive-cached','hyperdrive-nocache']) {
    const c = new Client({host:'127.0.0.1', port:parseInt(process.env.PORT,10),
      user:'postgres', database:'postgres', application_name:app,
      ssl:{rejectUnauthorized:false}}); // self-signed disposable cert
    await c.connect();
    const r = await c.query('SELECT id, data FROM record_revisions WHERE tenant_id=\$1', ['tenant-a']);
    if (r.rows.length !== 1) throw new Error(app + ': want 1 row, got ' + r.rows.length);
    console.log(app + ' rows=1 ' + JSON.stringify(r.rows[0]));
    await c.end();
  }
})().catch(e => { console.error('FAIL ' + e.message); process.exit(1); });
"
rm -rf "$WORK"
echo "per-request clients ok"

echo "PASS"
