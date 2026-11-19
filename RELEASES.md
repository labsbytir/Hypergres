# Releases

## v0.1.0 (2026-11-18)

First Hyperdrive-ready image: Wolfi-base + PostgreSQL 17.10-r1 + openssl,
self-sign/fail-closed TLS, entrypoint-managed `hostssl` SCRAM remote access.

- Tag: `v0.1.0` (image reference `hypergres:v0.1.0`).
- Layer digest (lockfile-pinned rebuild, `--arch=host` = arm64):
  `sha256:78a98727d703aae6ecc2bcb4e2d1e2ffbbc1b157c4384b1b4023c66c58f75bdb`
  (diffID `sha256:7fe83b94b2597c80ca31f1d2cb8f27578954ed88ae5905675f43736b49e15efd`).
- Rebuild-and-compare: same `apko.lock.json`, two consecutive builds —
  identical layer digest, identical diffID, bit-identical tarballs
  (`sha256:36126e5da1a90c0b452c5936d684e7c440fc6bfbd3eb74b3fc941375cefaf4d7`).
  Reproducible, no rotation to document.
- Lockfile: `apko.lock.json` committed in `bc0dd93`
  (`fix: image-owned hostssl SCRAM remote access, shape-script minors`);
  config checksum `sha256-2Amyvgu+XWt1vVkSntPJp6egY4mnyRD2Bh80O4y9bkc=`
  (116 pinned packages, both archs).

### Verify evidence (both suites re-run green on release day)

- `sh scripts/verify-build.sh` → PASS: entrypoint parity ok, `pg_isready`
  ok, PostgreSQL 17, `application_name` passthrough, `ssl=on`,
  `max_connections=100`, `shared_buffers=128MB`, `statement_timeout=30s`,
  `idle_in_transaction_session_timeout=1min`, `log_connections=on`,
  `password_encryption=scram-sha-256`, uid 65532, passwordless boot exits 1
  with FATAL, restart keeps exactly 1 hostssl line.
- `HARVY_CHECKOUT=<harvy> sh scripts/verify-hyperdrive-shape.sh` → PASS:
  `ssl=on`, migration `0001_operational.sql` applied, seed ok,
  `UPDATE record_revisions` rejected (append-only trigger), two host-side
  TCP SCRAM clients (`hyperdrive-cached` / `hyperdrive-nocache`) each
  returned 1 row over `127.0.0.1:5434`.

### Known deferred item

Single-file cert-mount clobber edge case: the entrypoint mints a
self-signed pair whenever either `$PGDATA/server.crt` or `server.key` is
absent, so mounting only one of the two files gets the other half
overwritten by a fresh self-signed counterpart (mixed pair). Mount both
files (or a directory containing both) until the entrypoint handles
half-mounted pairs.
