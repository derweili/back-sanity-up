#!/usr/bin/env bash
#
# sanity-backup.sh — export Sanity datasets, upload them to S3, ping a heartbeat.
# https://github.com/derweili/back-sanity-up
#
# Usage:
#   sanity-backup.sh [path/to/config.env]
#
# Config sources (first match wins):
#   1. first argument
#   2. $SANITY_BACKUP_CONFIG
#   3. ./sanity-backup.env next to this script
#   4. /etc/sanity-backup/sanity-backup.env
#   5. no file at all — plain environment variables (containers / serverless)
#
# One config = one Sanity project. For several projects, use one config file
# per project (see README).
#
# Requirements: bash, node/npx, aws CLI v2 (or rclone), curl, flock, gzip
#
set -Eeuo pipefail

SCRIPT_VERSION="1.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
CONFIG_FILE="${1:-${SANITY_BACKUP_CONFIG:-}}"
if [[ -z "$CONFIG_FILE" ]]; then
  for candidate in "$SCRIPT_DIR/sanity-backup.env" /etc/sanity-backup/sanity-backup.env; do
    [[ -f "$candidate" ]] && CONFIG_FILE="$candidate" && break
  done
fi

if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file '$CONFIG_FILE' not found" >&2
    exit 2
  fi
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
elif [[ -z "${SANITY_PROJECT_ID:-}" ]]; then
  echo "ERROR: no config file found and SANITY_PROJECT_ID is not set in the environment" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Defaults (anything here can be overridden in the config file / environment)
# ---------------------------------------------------------------------------
: "${SANITY_PROJECT_ID:?SANITY_PROJECT_ID is required}"
: "${SANITY_AUTH_TOKEN:?SANITY_AUTH_TOKEN is required}"
: "${SANITY_DATASETS:=production}"          # space separated: "production staging"
: "${SANITY_EXPORT_FLAGS:=}"                # e.g. "--no-drafts" or "--mode cursor"
: "${SANITY_CLI_VERSION:=latest}"           # npm version/range of @sanity/cli
: "${SANITY_CLI:=npx --yes -p @sanity/cli@${SANITY_CLI_VERSION} sanity}"  # Docker image sets "sanity"
: "${BACKUP_NAME:=$SANITY_PROJECT_ID}"      # S3 folder + log/lock names

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_PREFIX:=sanity-backups}"
: "${S3_ENDPOINT_URL:=}"                    # empty = AWS. Set for Hetzner/R2/Scaleway/MinIO
: "${S3_STORAGE_CLASS:=}"                   # e.g. STANDARD_IA (AWS only)
: "${UPLOAD_TOOL:=aws}"                     # aws | rclone
: "${RCLONE_REMOTE:=}"                      # e.g. "hetzner" (only for UPLOAD_TOOL=rclone)

: "${HEARTBEAT_URL:=}"                      # empty = no heartbeat
: "${HEARTBEAT_SEND_START:=false}"          # true for healthchecks.io (/start), false for Better Stack

: "${WORK_DIR:=/tmp/sanity-backup}"
: "${KEEP_LOCAL_COPIES:=0}"                 # 0 = delete local file right after upload
: "${LOG_DIR:=}"                            # empty = log to stdout only
: "${TZ_NAME:=${TZ:-UTC}}"                  # timezone used in file names

export DO_NOT_TRACK="${DO_NOT_TRACK:-1}"    # silence Sanity CLI telemetry notice

# aws CLI >= 2.23 sends new checksum headers that many non-AWS S3 providers
# (Hetzner, R2, older MinIO, ...) reject. Only send them when required.
if [[ -n "$S3_ENDPOINT_URL" ]]; then
  export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
RUN_LOG="$(mktemp)"
if [[ -n "$LOG_DIR" ]]; then
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_DIR/${BACKUP_NAME}.log" "$RUN_LOG") 2>&1
else
  exec > >(tee -a "$RUN_LOG") 2>&1
fi

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BACKUP_NAME" "$*"; }

# ---------------------------------------------------------------------------
# Heartbeat — healthchecks.io and Better Stack both accept POST to URL and URL/fail
# ---------------------------------------------------------------------------
heartbeat() {
  local suffix="$1"
  [[ -z "$HEARTBEAT_URL" ]] && return 0
  local url="${HEARTBEAT_URL%/}${suffix}"
  # The tail of the run log is sent as body and shows up in the monitoring UI.
  tail -c 10000 "$RUN_LOG" 2>/dev/null \
    | curl -fsS -m 15 --retry 3 -X POST --data-binary @- "$url" >/dev/null \
    || log "WARN: heartbeat ping failed ($url)"
}

# ---------------------------------------------------------------------------
# Failure handling
# ---------------------------------------------------------------------------
FINISHED=false
CURRENT_FILE=""
on_exit() {
  local code=$?
  if [[ "$FINISHED" != true ]]; then
    log "FAILED (exit code $code)"
    [[ -n "$CURRENT_FILE" ]] && rm -f "$CURRENT_FILE"   # don't leave partial exports behind
    heartbeat "/fail"
  fi
  rm -f "$RUN_LOG"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: '$1' not found in PATH"; exit 3; }; }
read -r -a SANITY_CMD <<< "$SANITY_CLI"
require "${SANITY_CMD[0]}"
require curl
require flock
require gzip
case "$UPLOAD_TOOL" in
  aws)    require aws ;;
  rclone) require rclone; : "${RCLONE_REMOTE:?RCLONE_REMOTE is required for UPLOAD_TOOL=rclone}" ;;
  *)      log "ERROR: unknown UPLOAD_TOOL '$UPLOAD_TOOL'"; exit 2 ;;
esac

mkdir -p "$WORK_DIR"

# Prevent overlapping runs of the same config (e.g. slow export + frequent schedule)
exec 9>"$WORK_DIR/${BACKUP_NAME}.lock"
if ! flock -n 9; then
  log "Another backup for '$BACKUP_NAME' is still running — skipping."
  FINISHED=true   # not a failure, don't ping /fail
  exit 0
fi

[[ "$HEARTBEAT_SEND_START" == true ]] && heartbeat "/start"

log "sanity-backup v$SCRIPT_VERSION — project=$SANITY_PROJECT_ID datasets=[$SANITY_DATASETS]"

# ---------------------------------------------------------------------------
# Upload helper
# ---------------------------------------------------------------------------
upload() {
  local file="$1" key="$2"
  case "$UPLOAD_TOOL" in
    aws)
      local args=(s3 cp "$file" "s3://$S3_BUCKET/$key" --only-show-errors)
      [[ -n "$S3_ENDPOINT_URL" ]]  && args+=(--endpoint-url "$S3_ENDPOINT_URL")
      [[ -n "$S3_STORAGE_CLASS" ]] && args+=(--storage-class "$S3_STORAGE_CLASS")
      aws "${args[@]}"
      ;;
    rclone)
      rclone copyto "$file" "$RCLONE_REMOTE:$S3_BUCKET/$key"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Export + upload each dataset
# ---------------------------------------------------------------------------
export SANITY_AUTH_TOKEN
TIMESTAMP="$(TZ="$TZ_NAME" date +%Y-%m-%d_%H-%M-%S)"
read -r -a EXTRA_FLAGS <<< "$SANITY_EXPORT_FLAGS"

for dataset in $SANITY_DATASETS; do
  filename="${TIMESTAMP}_${dataset}.tar.gz"
  local_path="$WORK_DIR/$filename"
  s3_key="${S3_PREFIX%/}/${BACKUP_NAME}/${dataset}/${filename}"
  CURRENT_FILE="$local_path"

  log "Exporting dataset '$dataset' → $local_path"
  (cd "$WORK_DIR" && "${SANITY_CMD[@]}" dataset export "$dataset" "$local_path" \
      --project "$SANITY_PROJECT_ID" --overwrite "${EXTRA_FLAGS[@]}")

  # The export must be a valid, non-empty gzip
  [[ -s "$local_path" ]] || { log "ERROR: export file is empty"; exit 4; }
  gzip -t "$local_path" || { log "ERROR: export file is not a valid gzip"; exit 4; }
  size="$(du -h "$local_path" | cut -f1)"

  log "Uploading $filename ($size) → s3://$S3_BUCKET/$s3_key"
  upload "$local_path" "$s3_key"
  log "Uploaded."

  [[ "$KEEP_LOCAL_COPIES" -eq 0 ]] && rm -f "$local_path"
  CURRENT_FILE=""
done

# ---------------------------------------------------------------------------
# Local retention — keep the newest N files per dataset.
# Remote retention belongs in an S3 lifecycle rule, not in this script.
# ---------------------------------------------------------------------------
if [[ "$KEEP_LOCAL_COPIES" -gt 0 ]]; then
  for dataset in $SANITY_DATASETS; do
    # shellcheck disable=SC2012
    ls -1t "$WORK_DIR"/*_"${dataset}".tar.gz 2>/dev/null \
      | tail -n +"$((KEEP_LOCAL_COPIES + 1))" \
      | xargs -r rm -f
  done
fi

log "Backup finished successfully."
FINISHED=true
heartbeat ""
