# AGENTS.md

Guidance for AI coding agents working on this repository.

## What this is

A Bash-based backup tool: `sanity dataset export` → `.tar.gz` → S3 upload → heartbeat ping. It ships as a standalone script (cron/systemd on a VPS) and as a Docker image (Coolify, Docker Compose, serverless container jobs). There is no application code, no Node project and no build step besides the Docker image.

## Layout

- `sanity-backup.sh` — the core script. **Must stay self-contained**: users install it with a single `curl` to `/opt/...`, without the rest of the repo.
- `sanity-backup.env.example` — the documented config template. Every variable the script reads must be listed here.
- `Dockerfile` — `node:22-alpine` + `@sanity/cli` (global, pinned via build arg) + `aws-cli` + `supercronic`. Runs as user `node`.
- `docker/entrypoint.sh` — container modes `cron` / `idle` / `run`.
- `docker/run-backups.sh` — runs one backup per `$CONFIG_DIR/*.env`, or one from plain env vars.
- `docker-compose.yml` — Coolify-ready compose (`${VAR:?}` = required in Coolify's UI).
- `examples/` — crontab and systemd template units (`sanity-backup@<config-name>.timer`).
- `.github/workflows/ci.yml` — ShellCheck + multi-arch image build/push to GHCR. CI must never run actual backups (bandwidth).

## Rules

- **Config is data, the script is code.** Never require users to edit `sanity-backup.sh`. New settings become variables with a default in the "Defaults" block (`: "${VAR:=default}"`), plus an entry in `sanity-backup.env.example`, the README config table and — if relevant for containers — `docker-compose.yml`.
- **Backwards compatibility:** existing variable names, the file name format `YYYY-MM-DD_HH-MM-SS_<dataset>.tar.gz` and the S3 key layout `<S3_PREFIX>/<BACKUP_NAME>/<dataset>/<file>` are a public contract. Lifecycle rules and restore scripts depend on them. Don't change them without a major version bump.
- **Exit codes:** any failure must exit non-zero and ping `<HEARTBEAT_URL>/fail` (handled by the `EXIT` trap via `FINISHED`). A skipped run because of the lock is *not* a failure.
- **Heartbeats are optional.** Empty `HEARTBEAT_URL` must skip all pings. Only `POST <url>`, `<url>/fail` and opt-in `<url>/start` — this is the intersection of healthchecks.io and Better Stack.
- **Never log secrets** (`SANITY_AUTH_TOKEN`, AWS keys). The log tail is sent to the heartbeat provider.
- **No retention logic for S3** in the script — that belongs in bucket lifecycle rules.
- Keep the script POSIX-tool-friendly for Debian/Ubuntu and Alpine: bash ≥ 4.4, coreutils/busybox, `flock`, `curl`, `gzip`. No `jq`, no Python.
- Bump `SCRIPT_VERSION` in `sanity-backup.sh` for behaviour changes.

## Checks before committing

```bash
shellcheck sanity-backup.sh docker/*.sh
bash -n sanity-backup.sh
docker build -t back-sanity-up:dev .
```

Testing without real credentials: point `SANITY_CLI` at a stub that writes a gzip file to its 4th argument, run a local S3 server (e.g. `moto_server -p 9000` or MinIO) with `S3_ENDPOINT_URL=http://127.0.0.1:9000`, and a tiny HTTP server for `HEARTBEAT_URL`. Verify: success path, failing dataset (→ `/fail`, non-zero exit, no partial file left), multi-config via `/config`, and the `cron`/`idle`/`run` container modes.

## Documentation

`README.md` is the user-facing doc (deployment options, config reference, restore). Update it together with any behaviour or config change.
