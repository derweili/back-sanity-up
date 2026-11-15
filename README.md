# back-sanity-up

Backs up [Sanity](https://www.sanity.io) datasets to S3-compatible storage on a schedule, with optional heartbeat monitoring.

- Uses the official Sanity CLI (`sanity dataset export`) — documents **and** assets
- Uploads to any S3-compatible storage (AWS, Hetzner Object Storage, Cloudflare R2, Scaleway, MinIO, …) via the `aws` CLI or `rclone`
- File names: `YYYY-MM-DD_HH-MM-SS_<dataset>.tar.gz`
- Heartbeat pings for [healthchecks.io](https://healthchecks.io) and [Better Stack](https://betterstack.com/uptime) (or anything that accepts `POST <url>` / `POST <url>/fail`)
- Config lives outside the script, so updating the script never touches your settings
- Runs as a plain shell script (cron / systemd), as a Docker container (Coolify, Docker Compose) or as a serverless job

```
sanity-backups/<BACKUP_NAME>/<dataset>/2026-11-15_03-15-00_production.tar.gz
```

> The export is a `.tar.gz`, not a `.zip` — it's Sanity's native format and can be restored as-is with `sanity dataset import`.

---

## Contents

- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Deployment options](#deployment-options)
  - [1. VPS with cron](#1-vps-with-cron)
  - [2. VPS with systemd timers](#2-vps-with-systemd-timers-recommended-for-plain-servers)
  - [3. Coolify](#3-coolify)
  - [4. Docker / Docker Compose (anywhere)](#4-docker--docker-compose-anywhere)
  - [5. Serverless jobs](#5-serverless-jobs)
  - [What doesn't fit](#what-doesnt-fit)
- [Heartbeat monitoring](#heartbeat-monitoring)
- [Retention](#retention)
- [Restoring a backup](#restoring-a-backup)
- [Security notes](#security-notes)

---

## How it works

```
sanity-backup.sh [config.env]
  ├─ load config (file or environment variables)
  ├─ lock (skip if the same config is already running)
  ├─ ping HEARTBEAT_URL/start            (optional)
  ├─ for each dataset:
  │    ├─ sanity dataset export → WORK_DIR/<timestamp>_<dataset>.tar.gz
  │    ├─ verify the file is a valid, non-empty gzip
  │    ├─ upload to s3://S3_BUCKET/S3_PREFIX/BACKUP_NAME/<dataset>/
  │    └─ delete the local copy (unless KEEP_LOCAL_COPIES > 0)
  └─ ping HEARTBEAT_URL                  (or HEARTBEAT_URL/fail on any error)
```

Exit code is `0` on success and non-zero on any failure, so every scheduler (cron, systemd, Coolify, serverless platforms) sees failures correctly.

### Files

| Path | Purpose |
| --- | --- |
| `sanity-backup.sh` | The backup script. Self-contained, no repo needed at runtime. |
| `sanity-backup.env.example` | Annotated config template. |
| `Dockerfile` | Image with Node, Sanity CLI, aws CLI and supercronic preinstalled. |
| `docker-compose.yml` | Coolify-ready compose file. |
| `docker/entrypoint.sh` | Container modes: `cron`, `idle`, `run`. |
| `docker/run-backups.sh` | Runs one backup per `/config/*.env` file, or one from env vars. |
| `examples/` | crontab and systemd timer templates. |

---

## Configuration

Everything is configured through variables — either in an env file passed as the first argument, or as plain environment variables (containers / serverless). See [`sanity-backup.env.example`](sanity-backup.env.example) for an annotated template.

Lookup order: first argument → `$SANITY_BACKUP_CONFIG` → `sanity-backup.env` next to the script → `/etc/sanity-backup/sanity-backup.env` → environment only.

**One config = one Sanity project.** For multiple projects, create one env file per project.

| Variable | Default | Description |
| --- | --- | --- |
| `SANITY_PROJECT_ID` | — (required) | Sanity project ID |
| `SANITY_AUTH_TOKEN` | — (required) | API token, **Viewer** role is enough |
| `SANITY_DATASETS` | `production` | Space-separated list of datasets |
| `SANITY_EXPORT_FLAGS` | — | Extra flags for `sanity dataset export`, e.g. `--no-drafts`, `--mode cursor` |
| `SANITY_CLI_VERSION` | `latest` | `@sanity/cli` version used via `npx` (pin it for stability). In Docker it's a build arg. |
| `SANITY_CLI` | `npx --yes -p @sanity/cli@$SANITY_CLI_VERSION sanity` | Command used to call the CLI. The Docker image sets `sanity`. |
| `BACKUP_NAME` | project ID | S3 folder name and log/lock name (e.g. the client name) |
| `S3_BUCKET` | — (required) | Target bucket |
| `S3_PREFIX` | `sanity-backups` | Key prefix inside the bucket |
| `S3_ENDPOINT_URL` | — | Empty for AWS; e.g. `https://fsn1.your-objectstorage.com` (Hetzner) |
| `S3_STORAGE_CLASS` | — | e.g. `STANDARD_IA` (AWS) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` | — | Standard `aws` CLI credentials (or use `AWS_PROFILE`) |
| `UPLOAD_TOOL` | `aws` | `aws` or `rclone` |
| `RCLONE_REMOTE` | — | rclone remote name (with `UPLOAD_TOOL=rclone`) |
| `HEARTBEAT_URL` | — | Heartbeat endpoint. Empty = skipped. |
| `HEARTBEAT_SEND_START` | `false` | Ping `<url>/start` before the run (healthchecks.io only) |
| `WORK_DIR` | `/tmp/sanity-backup` | Where exports are written before upload. Needs space for the biggest dataset incl. assets. |
| `KEEP_LOCAL_COPIES` | `0` | Keep the newest N exports locally too |
| `LOG_DIR` | — | Append logs to `$LOG_DIR/<BACKUP_NAME>.log`; empty = stdout only |
| `TZ_NAME` | `$TZ` or `UTC` | Timezone of the timestamp in file names |

When `S3_ENDPOINT_URL` is set, the script sets `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`, because aws CLI ≥ 2.23 sends checksum headers that many non-AWS providers reject.

### Docker-only variables

| Variable | Default | Description |
| --- | --- | --- |
| `BACKUP_MODE` | `cron` | `cron`, `idle` or `run` — see [Coolify](#3-coolify) and [Serverless](#5-serverless-jobs) |
| `CRON_SCHEDULE` | `0 3 * * *` | Schedule for `cron` mode (evaluated in `TZ`) |
| `RUN_ON_STARTUP` | `false` | Run one backup immediately when the container starts |
| `TZ` | `UTC` | Container timezone |
| `CONFIG_DIR` | `/config` | Folder with one `*.env` file per project (multi-project mode) |

---

## Deployment options

| Option | Best for | Run history / logs | Effort |
| --- | --- | --- | --- |
| [VPS + cron](#1-vps-with-cron) | Quick start | Log file + heartbeat | ⭐ |
| [VPS + systemd timer](#2-vps-with-systemd-timers-recommended-for-plain-servers) | Plain servers you manage | `journalctl` + heartbeat | ⭐⭐ |
| [Coolify](#3-coolify) | Already running Coolify | Container logs / Coolify task history | ⭐ |
| [Docker Compose](#4-docker--docker-compose-anywhere) | Any Docker host | `docker logs` | ⭐ |
| [Serverless jobs](#5-serverless-jobs) | No server at all | Platform console | ⭐⭐ |

### 1. VPS with cron

Requirements: `bash`, `node` (≥ 20, for `npx`), `aws` CLI v2 (or `rclone`), `curl`, `flock` (util-linux), `gzip`.

```bash
# Install the script
sudo mkdir -p /opt/back-sanity-up /etc/sanity-backup
sudo curl -fsSL https://raw.githubusercontent.com/derweili/back-sanity-up/main/sanity-backup.sh \
  -o /opt/back-sanity-up/sanity-backup.sh
sudo chmod +x /opt/back-sanity-up/sanity-backup.sh

# Dedicated user
sudo useradd --system --create-home --shell /usr/sbin/nologin sanity-backup

# One config per project
sudo curl -fsSL https://raw.githubusercontent.com/derweili/back-sanity-up/main/sanity-backup.env.example \
  -o /etc/sanity-backup/client-a.env
sudo nano /etc/sanity-backup/client-a.env
sudo chown root:sanity-backup /etc/sanity-backup/*.env
sudo chmod 640 /etc/sanity-backup/*.env
sudo install -d -o sanity-backup /var/log/sanity-backup /var/tmp/sanity-backup

# Test once
sudo -u sanity-backup /opt/back-sanity-up/sanity-backup.sh /etc/sanity-backup/client-a.env
```

Then schedule it — see [`examples/crontab`](examples/crontab):

```cron
# /etc/cron.d/sanity-backup
15 3 * * * sanity-backup /opt/back-sanity-up/sanity-backup.sh /etc/sanity-backup/client-a.env
```

Updating = replacing `sanity-backup.sh`. Configs stay untouched.

### 2. VPS with systemd timers (recommended for plain servers)

Same install as above, but scheduled with systemd instead of cron. Advantages: logs in `journalctl`, missed runs are caught up after downtime (`Persistent=true`), randomised start times so several projects don't start at once.

The units in [`examples/systemd/`](examples/systemd) are templates — the part after `@` is the config file name:

```bash
sudo cp examples/systemd/sanity-backup@.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sanity-backup@client-a.timer   # uses /etc/sanity-backup/client-a.env
sudo systemctl enable --now sanity-backup@client-b.timer

systemctl list-timers 'sanity-backup@*'
sudo systemctl start sanity-backup@client-a.service        # run now
journalctl -u sanity-backup@client-a.service -f            # logs
```

### 3. Coolify

The repo contains a [`docker-compose.yml`](docker-compose.yml) made for Coolify:

1. **New Resource → Public Repository** (or Private via GitHub App) → `https://github.com/derweili/back-sanity-up`
2. **Build Pack: Docker Compose**
3. Fill in the variables in **Environment Variables** (required ones are marked by Coolify)
4. No domain or port needed — deploy

There are two ways to schedule backups. Pick one with `BACKUP_MODE`:

**a) `BACKUP_MODE=cron` (default)** — the container schedules itself with [supercronic](https://github.com/aptible/supercronic) using `CRON_SCHEDULE` and `TZ`. Logs show up in Coolify's log view; failures are reported via the heartbeat. Self-contained, nothing to click in Coolify.

**b) `BACKUP_MODE=idle` + Coolify Scheduled Tasks** — the container just idles, and Coolify triggers the backup:

- Resource → **Configuration → Scheduled Tasks → + Add**
- Command: `run-backups`
- Container: `sanity-backup`
- Frequency: e.g. `15 3 * * *`
- **Timeout: raise it** — Coolify's default is 300 s; allowed range is 60–36000 s. Large datasets with assets can take a while.

Advantage of (b): every run, its output and its exit status are listed in Coolify's task history, and you get "Execute Now" for manual runs.

**Multiple projects in one Coolify resource:** mount a folder of env files (one per project) to `/config` (see the commented `volumes:` block in the compose file). `run-backups` then backs up every `*.env` in that folder one after another and fails if any of them failed. Each file can carry its own `HEARTBEAT_URL`. In that case remove the `:?` "required" markers from the compose file or leave the global variables as defaults.

Alternatively, create one Coolify resource per project — simpler to reason about, slightly more overhead.

### 4. Docker / Docker Compose (anywhere)

```bash
# Build locally
docker build -t back-sanity-up .
# or pin the CLI version
docker build --build-arg SANITY_CLI_VERSION=8 -t back-sanity-up .

# One-off backup
docker run --rm --env-file client-a.env back-sanity-up run

# Scheduled, multiple projects
docker run -d --restart unless-stopped \
  -e CRON_SCHEDULE="15 3 * * *" -e TZ=Europe/Berlin \
  -v /etc/sanity-backup:/config:ro \
  back-sanity-up
```

The image is also published by CI to `ghcr.io/derweili/back-sanity-up` (`latest`, `sha-…`, and semver tags for `v*` git tags), for `linux/amd64` and `linux/arm64`.

Container modes (`BACKUP_MODE` or first argument):

| Mode | Behaviour |
| --- | --- |
| `cron` | Long-running, runs `run-backups` on `CRON_SCHEDULE` |
| `idle` | Long-running, does nothing — an external scheduler runs `run-backups` inside it |
| `run` | Runs once and exits with the backup's exit code |
| anything else | Executed as a command (e.g. `sh`) |

### 5. Serverless jobs

Every platform that can run a **container image on a schedule** works with `BACKUP_MODE=run` (or command `run`). Config comes from environment variables / the platform's secret store. Things to check per platform: max runtime, ephemeral disk size (must fit your largest export incl. assets) and egress cost.

**Scaleway Serverless Jobs** (EU — Paris, Amsterdam, Warsaw) — the best fit if you want EU hosting:
- Runs container images with cron triggers (with timezone), up to **24 h** per run, up to **10 GB** ephemeral storage, **amd64 only**
- Pairs naturally with Scaleway Object Storage (`S3_ENDPOINT_URL=https://s3.fr-par.scw.cloud`)
- Setup: push the image to Scaleway Container Registry → create a Job definition with the image, startup command `entrypoint run`, env vars + secrets (token, keys) → add a cron trigger
- Pay per second of runtime — a nightly backup costs cents

**Google Cloud Run Jobs + Cloud Scheduler** — container jobs with long timeouts, EU regions available. Create a job from the image with args `run`, put secrets in Secret Manager, trigger with Cloud Scheduler.

**AWS ECS Fargate scheduled tasks (EventBridge Scheduler)** — no runtime limit, configurable ephemeral storage; most setup effort (task definition, IAM roles, VPC). The task's IAM role can replace the access keys.

**Kubernetes `CronJob`** — if you already have a cluster: image `ghcr.io/derweili/back-sanity-up`, args `["run"]`, `concurrencyPolicy: Forbid`, env from a Secret.

### What doesn't fit

- **GitHub Actions** — every run downloads all assets through the runner; with many projects that burns through minutes and bandwidth. (CI here only *builds* the image.)
- **AWS Lambda** — 15-minute hard limit; exports with many assets can exceed it.
- **Cloudflare Workers / Vercel Cron** — can't run the Sanity CLI, strict CPU/memory limits.

---

## Heartbeat monitoring

Set `HEARTBEAT_URL` to get alerted when a backup fails **or doesn't run at all** (server down, cron broken, …). If it's empty, heartbeats are skipped.

| Event | Request |
| --- | --- |
| Start (only with `HEARTBEAT_SEND_START=true`) | `POST <url>/start` |
| Success | `POST <url>` |
| Failure | `POST <url>/fail` |

The last ~10 KB of the run log is sent as the request body, so you can see the error in the monitoring UI.

**healthchecks.io** — create a check, set period = your schedule (e.g. 1 day) and a grace time longer than a backup takes.
```
HEARTBEAT_URL=https://hc-ping.com/<uuid>
HEARTBEAT_SEND_START=true   # healthchecks.io then also measures duration
```

**Better Stack** — Uptime → Heartbeats → create one with the matching period.
```
HEARTBEAT_URL=https://uptime.betterstack.com/api/v1/heartbeat/<token>
HEARTBEAT_SEND_START=false  # Better Stack has no /start endpoint
```

Use one heartbeat per project, so you know which one failed.

---

## Retention

The script never deletes anything in S3. Configure a **lifecycle rule** on the bucket instead (e.g. delete objects under `sanity-backups/` after 30 days). Supported by AWS, Hetzner, R2, Scaleway and MinIO.

For tamper-proof backups, enable **object lock / versioning** on the bucket if your provider supports it.

---

## Restoring a backup

```bash
aws s3 cp s3://my-backups/sanity-backups/client-a/production/2026-11-15_03-15-00_production.tar.gz .
# (add --endpoint-url for non-AWS providers)

# Restore into a new dataset first and check it
npx -p @sanity/cli sanity dataset import 2026-11-15_03-15-00_production.tar.gz restore-test --project <id>

# Replace an existing dataset (destructive!)
npx -p @sanity/cli sanity dataset import 2026-11-15_03-15-00_production.tar.gz production --project <id> --replace
```

Test a restore every now and then — a backup you've never restored is a guess.

---

## Security notes

- **Sanity token:** a dedicated token with the **Viewer** role. Exports need read access only.
- **S3 credentials:** a key scoped to the backup bucket, ideally write-only (`PutObject`) — then a compromised server can't read or delete old backups.
- **Config files** contain secrets: `chmod 640`, owned by root, readable by the backup user only. `*.env` is git-ignored.
- **Docker image** runs as the unprivileged `node` user.

---

## License

No license file yet — add one before others reuse the code.
