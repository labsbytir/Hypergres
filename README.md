# Hypergres

Wolfi-based PostgreSQL 17 container image for Cloudflare Hyperdrive.

## Build

Requires [apko](https://github.com/chainguard-dev/apko) v1.5.x and podman.

```bash
apko build apko.yaml hypergres:v0.1.0 hypergres-build.tar --sbom=false --lockfile apko.lock.json
podman load < hypergres-build.tar
```

`apko.yaml` is the single source of truth; `entrypoint.sh` is a derived
byte-identical copy of its `shell-fragment` (marked `FRAGMENT-BEGIN/END` —
do not edit by hand). `postgresql.conf` documents the effective `-c` flags
(mount-only reference; the image passes each value as a `-c` flag because
apko cannot embed host files). Regenerate the pin after any `apko.yaml`
change: `apko lock apko.yaml --output apko.lock.json`.

## Usage

First start requires a password (fail closed — passwordless boot exits 1):

```bash
podman run -d --name hypergres \
  -e POSTGRES_PASSWORD='...' \
  -p 5432:5432 hypergres:v0.1.0
```

Defaults: `ssl=on` (self-signed cert minted on first boot if no
operator cert is present), `max_connections=100`, `shared_buffers=128MB`,
`statement_timeout=30s`, `idle_in_transaction_session_timeout=60s`,
`log_connections=on`, `password_encryption=scram-sha-256`. Runs as uid 65532
(`postgres`). Trust-auth data dirs from older builds FATAL on boot until
re-run with `-e POSTGRES_PASSWORD` (intended).

To use a real certificate, place `server.crt`/`server.key` in `$PGDATA`
before first start (or mount a directory containing both); the entrypoint
skips minting when both files exist.

## Hyperdrive wiring

The entrypoint owns remote access: `pg_hba.conf` gets
`hostssl all all 0.0.0.0/0 scram-sha-256` (idempotent, exactly-once), so
Hyperdrive reaches Postgres over TCP with TLS + SCRAM. Connect with
`sslmode=require` (self-signed default cert) or `verify-full` against a
mounted CA. Disposable end-to-end proof:
`HARVY_CHECKOUT=<harvy> sh scripts/verify-hyperdrive-shape.sh`
(applies Harvy `0001_operational.sql`, proves the append-only trigger, and
runs two per-request `pg` clients over host-side TCP).

## Pool / TLS notes

- `max_connections=100`: size the Hyperdrive pool below this, leaving
  headroom for admin/monitoring connections.
- `statement_timeout=30s` + `idle_in_transaction_session_timeout=60s` bound
  runaway transactions; long migrations may need a direct (non-pooled)
  connection with relaxed timeouts.
- First-boot TLS is encrypted-but-untrusted (self-signed); mount a real
  cert for trusted TLS — no code change needed.

## Digest-pin consumption

Release `v0.1.0` (see `RELEASES.md`): layer digest
`sha256:78a98727d703aae6ecc2bcb4e2d1e2ffbbc1b157c4384b1b4023c66c58f75bdb`,
pinned Wolfi package set in `apko.lock.json`. The Harvy sync plan consumes
this digest as `image.ref`.
