# back-sanity-up — Sanity dataset backups to S3
# https://github.com/derweili/back-sanity-up

FROM node:22-alpine

# Pin the Sanity CLI at build time so runs are reproducible and need no npm download.
ARG SANITY_CLI_VERSION=latest

RUN apk add --no-cache bash curl flock tzdata aws-cli supercronic \
 && npm install -g "@sanity/cli@${SANITY_CLI_VERSION}" \
 && npm cache clean --force

COPY sanity-backup.sh       /usr/local/bin/sanity-backup
COPY docker/run-backups.sh  /usr/local/bin/run-backups
COPY docker/entrypoint.sh   /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/sanity-backup /usr/local/bin/run-backups /usr/local/bin/entrypoint \
 && mkdir -p /work /config \
 && chown node:node /work

ENV SANITY_CLI=sanity \
    WORK_DIR=/work \
    CONFIG_DIR=/config \
    BACKUP_MODE=cron \
    CRON_SCHEDULE="0 3 * * *" \
    TZ=UTC \
    DO_NOT_TRACK=1

USER node
WORKDIR /work
ENTRYPOINT ["entrypoint"]
