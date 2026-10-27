#!/bin/bash

scale_backend() {
  local scale_value="$SERVER_REPLICAS"
  local stack="$APP_LOWER-$STACK_NAME"

  echo "Scaling backend to $scale_value."

  docker service scale "${stack}_${stack}-server=$scale_value" || true
}

scale_backend
