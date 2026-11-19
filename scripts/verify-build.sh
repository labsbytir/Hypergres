#!/bin/sh
# Task 1 verify: build the apko image, load it into podman, boot it, and assert
# pg_isready + version + application_name passthrough.
set -eu

TAG="${TAG:-hypergres:test}"
NAME="${NAME:-hypergres-verify}"
ARCH="${ARCH:-host}"

echo "==> apko build $TAG"
# NOTE: apko v1.5.x requires an explicit output path (older versions defaulted
# to <tag>.tar, as in the original Task 1 brief command).
OUT="hypergres-build.tar"
rm -f "$OUT" "$TAG"-*.tar hypergres-*.tar
apko build apko.yaml "$TAG" "$OUT" --sbom=false --arch="$ARCH"

TARBALL="$OUT"
echo "==> /opt/podman/bin/podman load < $TARBALL"
IMAGE="$(/opt/podman/bin/podman load < "$TARBALL" | sed -n 's/^Loaded image: //p' | tail -1)"
if [ -z "${IMAGE:-}" ]; then
  echo "FAIL: podman load produced no image" >&2
  exit 1
fi
echo "loaded: $IMAGE"

/opt/podman/bin/podman rm -f "$NAME" >/dev/null 2>&1 || true
echo "==> podman run $NAME"
/opt/podman/bin/podman run -d --name "$NAME" -p 5433:5432 "$IMAGE" >/dev/null

echo "==> waiting for pg_isready (60s)"
for i in $(seq 1 60); do
  if /opt/podman/bin/podman exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "FAIL: pg_isready never ok" >&2
    /opt/podman/bin/podman logs "$NAME" | tail -20 >&2 || true
    exit 1
  fi
  sleep 1
done
echo "pg_isready ok"

echo "==> SELECT version()"
/opt/podman/bin/podman exec "$NAME" psql -U postgres -h 127.0.0.1 -tAc "SELECT version();" | grep -q "PostgreSQL 17" \
  || { echo "FAIL: not PostgreSQL 17" >&2; exit 1; }
echo "version ok (PostgreSQL 17)"

echo "==> application_name passthrough"
/opt/podman/bin/podman exec "$NAME" psql "host=127.0.0.1 user=postgres application_name=hypergres-verify dbname=postgres" \
  -tAc "SHOW application_name;" | grep -q "hypergres-verify" \
  || { echo "FAIL: application_name not passed through" >&2; exit 1; }
echo "application_name ok"

/opt/podman/bin/podman rm -f "$NAME" >/dev/null
echo "PASS"
