#!/usr/bin/env bash
#
# Container entrypoint. Modes (first argument, or $BACKUP_MODE):
#
#   cron  (default) Long-running. Runs backups on $CRON_SCHEDULE via supercronic.
#   idle            Long-running, does nothing. For schedulers that exec into the
#                   container (e.g. Coolify "Scheduled Tasks" → command: run-backups).
#   run             One-shot: run backups once, exit with their status code.
#                   For serverless jobs (Scaleway Jobs, Cloud Run Jobs, Fargate, k8s CronJob).
#   <anything else> Executed as a command (e.g. "sh" for debugging).
#
set -Eeuo pipefail

MODE="${1:-${BACKUP_MODE:-cron}}"
[[ $# -gt 0 ]] && shift

case "$MODE" in
  cron)
    : "${CRON_SCHEDULE:=0 3 * * *}"
    echo "back-sanity-up: cron mode, schedule '$CRON_SCHEDULE' (TZ=${TZ:-UTC})"
    printf '%s run-backups\n' "$CRON_SCHEDULE" > /tmp/crontab
    if [[ "${RUN_ON_STARTUP:-false}" == true ]]; then
      run-backups || echo "back-sanity-up: startup run failed (continuing with schedule)"
    fi
    # supercronic passes the container environment to jobs, logs to stdout and
    # handles signals properly as PID 1 (unlike classic cron).
    exec supercronic -passthrough-logs /tmp/crontab
    ;;
  idle)
    echo "back-sanity-up: idle mode — trigger backups with 'run-backups'"
    trap 'exit 0' TERM INT
    sleep infinity &
    wait
    ;;
  run)
    exec run-backups "$@"
    ;;
  *)
    exec "$MODE" "$@"
    ;;
esac
