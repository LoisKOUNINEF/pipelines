#!/bin/bash

set -eo pipefail

POSTGRES_SERVICE="${APP_LOWER}-${STACK_NAME}_postgres"
if ! docker service ls --format "{{.Name}}" | grep -qx "$POSTGRES_SERVICE"; then
  echo "PostgreSQL service '$POSTGRES_SERVICE' is not running."
  exit 1
fi

POSTGRES_CONTAINER=$(docker ps -q -f "name=${POSTGRES_SERVICE}_" | head -n 1)

read_secret() {
  docker exec "$POSTGRES_CONTAINER" cat "/run/secrets/$1" 2>/dev/null || true
}

PG_USER=$(read_secret "${APP_SNAKE}_${STACK_NAME}_db_user")
PG_PASSWORD=$(read_secret "${APP_SNAKE}_${STACK_NAME}_db_password")
DB_NAME=$(read_secret "${APP_SNAKE}_${STACK_NAME}_db_name")
# Passed by the deploy workflow (ENCRYPTION_PASSWORD secret), or mounted as a swarm secret
ENCRYPTION_PASSWORD="${ENCRYPTION_PASSWORD:-$(read_secret encryption_password)}"
# passed by name (-e NAME, -pass env:NAME): values in arguments are visible to every VPS user in ps
export PGPASSWORD="$PG_PASSWORD" ENCRYPTION_PASSWORD

if [[ -z "$PG_USER" || -z "$PG_PASSWORD" || -z "$DB_NAME" || -z "$ENCRYPTION_PASSWORD" ]]; then
  echo "Error: Missing required database credentials or encryption password."
  exit 1
fi

BACKUP_DIR="${BACKUP_DIR:-/backups}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

mkdir -p "$BACKUP_DIR"

# per stack: staging and production often share the database name and BACKUP_DIR
BACKUP_PREFIX="${APP_SNAKE}_${STACK_NAME}_backup_"
BACKUP_FILE="$BACKUP_DIR/$BACKUP_PREFIX$TIMESTAMP.sql.gz.enc"

if ! docker exec -e PGPASSWORD "$POSTGRES_CONTAINER" pg_dump --clean --if-exists -U "$PG_USER" "$DB_NAME" | \
  gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:ENCRYPTION_PASSWORD > "$BACKUP_FILE"; then
  echo "Backup failed."
  rm -f "$BACKUP_FILE"
  exit 1
fi

echo "Backup successful: $BACKUP_FILE"

# read by rollback.sh to restore this exact backup
echo "$BACKUP_FILE" > ".last-backup-${SERVICE_NAME}-${STACK_NAME}"

find "$BACKUP_DIR" -type f -name "${BACKUP_PREFIX}*.sql.gz.enc" -mtime +7 -exec rm {} \;

exit 0
