#!/bin/bash

healthcheck() {
  local timeout="${HEALTHCHECK_TIMEOUT:-90}"
  local start_time=$(date +%s)
  local all_healthy=true

  while true; do
    all_healthy=true
    services=$(docker service ls --format "{{.Name}}" --filter "name="$APP_LOWER"-"$STACK_NAME"")

    for service in $services; do
      # migrations run once and exit, they're never "running"
      case "$service" in
        *-migrations) continue ;;
      esac

      replicas=$(docker service ls --filter name=$service --format "{{.Replicas}}")
      running=$(echo $replicas | cut -d'/' -f1)
      expected=$(echo $replicas | cut -d'/' -f2)

      if [ "$running" = "$expected" ]; then
        echo "$service is healthy ($replicas)"
      else
        echo "$service is unhealthy ($replicas)"
        # tasks that never started have no logs, their error is only in the task list
        docker service ps --no-trunc --format "  {{.Name}} {{.CurrentState}} {{.Error}}" "$service" | head -n 3
        all_healthy=false
      fi
    done

    if $all_healthy; then
      echo "All services are healthy"
      return 0
    fi

    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    if [ $elapsed -ge $timeout ]; then
      echo "Timeout reached. Not all services are healthy."
      return 1
    fi

    echo "Waiting for all services to become healthy..."
    sleep 10
  done
}

script_dir="$(dirname "$0")"
if ! healthcheck; then
  "$script_dir/rollback.sh"
  exit 1
fi
