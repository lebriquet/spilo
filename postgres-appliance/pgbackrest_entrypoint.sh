#!/bin/bash
PGB_DEFAULT_CONFIG=/run/etc/pgbackrest.conf

function log {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - pgbackrest bootstrap - $1"
}

function is_gcs {
  if [ -z "${PGB_REPO1_GCS_BUCKET}" ] || [ -z "${PGB_REPO1_GCS_ENDPOINT}" ] || \
     [ -z "${PGB_REPO1_GCS_KEY}" ] || [ -z "${PGB_REPO1_GCS_KEY_SECRET}" ] || \
     [ -z "${PGB_REPO1_GCS_KEY_TYPE}" ]
  then
      echo false
  else
      echo true
  fi
}

function is_s3 {
if [ -z "${PGB_REPO1_S3_BUCKET}" ] || [ -z "${PGB_REPO1_S3_ENDPOINT}" ] || \
   [ -z "${PGB_REPO1_S3_KEY}" ] || [ -z "${PGB_REPO1_S3_KEY_SECRET}" ] || \
   [ -z "${PGB_REPO1_S3_REGION}" ] || [ -z "${PGB_REPO1_CIPHER_PASSWORD}" ]
then
   echo false
else
   echo true
fi
}

function config_gcs {
cat > "${PGB_CONFIG}" <<__EOT__
[${PGB_STANZA}]
pg1-path=${PGDATA:-/home/postgres/pgdata/pgroot/data}
pg1-socket-path=${PGSOCKET:-/var/run/postgresql}
pg1-port=${PGPORT:-5432}
pg1-user=${POSTGRES_USER:-postgres}
pg1-host-user=${POSTGRES_USER:-postgres}
log-level-console=info
[global]
process-max=4
log-level-file=detail
repo1-path=${PGB_REPO1_PATH}
repo1-retention-diff=${PGB_REPO1_RETENTION_DIFF:-2}
repo1-retention-full=${PGB_REPO1_RETENTION_FULL:-5}
repo1-gcs-bucket=${PGB_REPO1_GCS_BUCKET}
repo1-gcs-endpoint=${PGB_REPO1_GCS_ENDPOINT}
#repo1-gcs-key=${PGB_REPO1_GCS_KEY}
repo1-gcs-key=${PGB_REPO1_GCS_KEY_TYPE}
#repo1-gcs-key-secret=${PGB_REPO1_GCS_KEY_SECRET}
#repo1-cipher-type=${PGB_REPO1_CIPHER_TYPE}
#repo1-cipher-pass=${PGB_REPO1_CIPHER_PASSWORD}
repo1-type=gcs
start-fast=y
[global:archive-push]
compress-level=3
__EOT__

}

function config_s3 {
cat > "${PGB_CONFIG}" <<__EOT__
[${PGB_STANZA}]
pg1-path=${PGDATA:-/home/postgres/pgdata/pgroot/data}
pg1-socket-path=${PGSOCKET:-/var/run/postgresql}
pg1-port=${PGPORT:-5432}
pg1-user=${POSTGRES_USER:-postgres}
pg1-host-user=${POSTGRES_USER:-postgres}
[global]
process-max=4
log-level-file=detail
repo1-path=${PGB_REPO1_PATH}
repo1-cipher-type=${PGB_REPO1_CIPHER_TYPE}
repo1-retention-diff=2
repo1-retention-full=2
repo1-s3-bucket=${PGB_REPO1_S3_BUCKET}
repo1-s3-endpoint=${PGB_REPO1_S3_ENDPOINT}
repo1-s3-key=${PGB_REPO1_S3_KEY}
repo1-s3-key-secret=${PGB_REPO1_S3_KEY_SECRET}
repo1-s3-region=${PGB_REPO1_S3_REGION}
repo1-cipher-pass=${PGB_REPO1_CIPHER_PASSWORD}
repo1-type=s3
[global:archive-push]
compress-level=3
__EOT__
}

if [ -z "${PGB_STANZA}" ] || [ -z "${PGB_REPO1_PATH}" ] || \
  [[ "$(is_gcs)" == "false" && "$(is_s3)" == "false" ]]
then
    log "Environment variable USE_PGBACKREST is set, but one of the following environment variables is not:"
    log "* PGB_STANZA=${PGB_STANZA}"
    log "* PGB_REPO1_PATH=${PGB_REPO1_PATH}"
    log "* "
    log "* PGB_REPO1_GCS_BUCKET=${PGB_REPO1_GCS_BUCKET}"
    log "* PGB_REPO1_GCS_ENDPOINT=${PGB_REPO1_GCS_ENDPOINT}"
    log "* PGB_REPO1_GCS_KEY=${PGB_REPO1_GCS_KEY}"
    log "* PGB_REPO1_GCS_KEY_TYPE=${PGB_REPO1_GCS_KEY_TYPE}"
    log "* PGB_REPO1_GCS_KEY_SECRET=${PGB_REPO1_GCS_KEY_SECRET/.*/*}"
    log "* "
    log "* "
    log "* "
    log "* PGB_REPO1_S3_BUCKET=${PGB_REPO1_S3_BUCKET}"
    log "* PGB_REPO1_S3_ENDPOINT=${PGB_REPO1_S3_ENDPOINT}"
    log "* PGB_REPO1_S3_KEY=${PGB_REPO1_S3_KEY}"
    log "* PGB_REPO1_S3_KEY_SECRET=${PGB_REPO1_S3_KEY_SECRET/.*/*}"
    log "* PGB_REPO1_S3_REGION=${PGB_REPO1_S3_REGION}"
    log "* PGB_REPO1_CIPHER_PASSWORD=${PGB_REPO1_CIPHER_PASSWORD/.*/*}"
    log "* "
    log "PgBackrest will not be configured."
    #log "PgBackrest cannot check or create the stanza."
    exit 1
 fi


# The pgBackRest configuration needs to be shared by all containers in the pod
# at some point in the future we may fetch it from an s3-bucket or some environment configuration,
# however, for now we store the file in a mounted volume that is accessible to all pods.
# umask 0077
mkdir -p "$(dirname "${PGB_CONFIG}")"
# если есть конфиг gcs, пишем его, если нет, пишем для s3
if [ "$(is_gcs)" == "true" ]; then
    config_gcs
else
    config_s3
fi

if [ "${PGB_CONFIG}" != "${PGB_DEFAULT_CONFIG}" ]
then
    mkdir -p "$(dirname "${PGB_DEFAULT_CONFIG}")"
    rm -f ${PGB_DEFAULT_CONFIG}
    ln -s ${PGB_CONFIG} ${PGB_DEFAULT_CONFIG}
fi

log "Waiting for PostgreSQL to become available"
while ! pg_isready -h "${PGSOCKET}" -q; do
    sleep 3
done

# Only primary node check the stanza and in case it doesn't exist, create it.
log "Verify Patroni is the primary node"
if [ "$(psql -U postgres -c "SELECT pg_is_in_recovery()::text" -AtXq)" == "false" ]
then
    log "Check if PgBackrest stanza ${PGB_STANZA} is correctly configured"
    su - postgres -c "pgbackrest check --config-path /run/etc --stanza=${PGB_STANZA}" 2>/dev/null || {
        log "Creating pgBackrest stanza ${PGB_STANZA}"
        su - postgres -c "pgbackrest stanza-create --config-path /run/etc --log-level-stderr=info --stanza=${PGB_STANZA}" || exit 1
    }
fi

#log "Starting pgBackrest api to listen for backup requests"
#python3 /scripts/pgbackrest-rest.py --stanza=${PGB_STANZA} --loglevel=debug