#!/bin/bash

set -eo pipefail

if [[ -z "$STACK_NAME" ]]; then
  echo "Error: STACK_NAME is not set. Please provide it as an environment variable or argument."
  exit 1
fi

POSTGRES_SERVICE="${APP_LOWER}-${STACK_NAME}_postgres"
if ! docker service ls --format "{{.Name}}" | grep -q "$POSTGRES_SERVICE"; then
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

if [[ -z "$PG_USER" || -z "$PG_PASSWORD" || -z "$DB_NAME" || -z "$ENCRYPTION_PASSWORD" ]]; then
  echo "Error: Missing required database credentials or encryption password."
  exit 1
fi

BACKUP_DIR="${BACKUP_DIR:-/backups}"
if [[ -z "$BACKUP_FILE" ]]; then
  BACKUP_FILE=$(ls -t "$BACKUP_DIR"/${DB_NAME}_backup_*.sql.gz.enc 2>/dev/null | head -n 1 || true)
  if [[ -z "$BACKUP_FILE" ]]; then
    echo "Error: No backup file found in '$BACKUP_DIR'."
    exit 1
  fi
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "Error: Backup file '$BACKUP_FILE' does not exist."
  exit 1
fi

if ! openssl enc -d -aes-256-cbc -salt -pbkdf2 -pass pass:"$ENCRYPTION_PASSWORD" -in "$BACKUP_FILE" | \
  gunzip | docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 -q -U "$PG_USER" "$DB_NAME" > /dev/null; then
  echo "Restore failed."
  exit 1
fi

echo "Restore successful: $BACKUP_FILE"

exit 0
