#!/bin/bash

# Keeps the components of ALL_COMPONENTS ("name:dockerfile:dir" list) whose dir, or one of
# SHARED_PATHS (comma-separated globs), changed since origin/main, as "name:dockerfile".
# Builds everything when nothing matched (first deployment, workflow-only change) or without origin/main.

IFS=',' read -ra all_components <<< "$ALL_COMPONENTS"
IFS=',' read -ra shared_paths <<< "$SHARED_PATHS"

all=()
for component in "${all_components[@]}"; do
  all+=("${component%:*}")
done

output() {
  local joined
  joined=$(IFS=','; echo "$*")
  echo "Components to build: $joined"
  echo "components=$joined" >> $GITHUB_OUTPUT
}

if ! git rev-parse --verify --quiet origin/main > /dev/null; then
  echo "No origin/main, building all components"
  output "${all[@]}"
  exit 0
fi

changed_files=$(git diff --name-only origin/main...HEAD)

shared_changed=false
while IFS= read -r file; do
  [ -z "$file" ] && continue
  for pattern in "${shared_paths[@]}"; do
    # unquoted pattern: glob match, "**" matches across "/"
    if [[ "$file" == $pattern ]]; then
      echo "Shared path changed: $file"
      shared_changed=true
    fi
  done
done <<< "$changed_files"

if $shared_changed; then
  output "${all[@]}"
  exit 0
fi

selected=()
for component in "${all_components[@]}"; do
  dir="${component##*:}"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if [ "$dir" = "." ] || [[ "$file" == "$dir"/* ]]; then
      selected+=("${component%:*}")
      break
    fi
  done <<< "$changed_files"
done

if [ ${#selected[@]} -eq 0 ]; then
  echo "No component changed, building all components"
  output "${all[@]}"
  exit 0
fi

output "${selected[@]}"
