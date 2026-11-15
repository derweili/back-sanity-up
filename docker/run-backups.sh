#!/usr/bin/env bash
#
# Runs sanity-backup for every *.env file in $CONFIG_DIR (default /config).
# If there are none, runs once using plain environment variables.
# Exits non-zero if any backup failed, but always attempts all of them.
#
set -uo pipefail

CONFIG_DIR="${CONFIG_DIR:-/config}"
shopt -s nullglob
configs=("$CONFIG_DIR"/*.env)

if [[ ${#configs[@]} -eq 0 ]]; then
  exec sanity-backup
fi

failed=0
for config in "${configs[@]}"; do
  # Each config runs in its own process, so variables don't leak between projects.
  sanity-backup "$config" || { echo "back-sanity-up: FAILED: $config"; failed=$((failed + 1)); }
done

if [[ $failed -gt 0 ]]; then
  echo "back-sanity-up: $failed of ${#configs[@]} backups failed"
  exit 1
fi
