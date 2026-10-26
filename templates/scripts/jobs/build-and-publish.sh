#!/bin/bash

build_and_publish() {
  local image="ghcr.io/${REPO_LOWER}-$1:${GITHUB_SHA}"

  docker build --platform linux/amd64 -t "$image" -f "./$2" . || exit 1
  docker push "$image" || exit 1
}

# COMPONENTS (backend/fullstack): comma-separated "name:dockerfile" list, one image per component
if [ -n "$COMPONENTS" ]; then
  IFS=',' read -ra components <<< "$COMPONENTS"

  for component in "${components[@]}"; do
    build_and_publish "${SERVICE_NAME}-${component%%:*}" "${component#*:}"
  done
else
  build_and_publish "${SERVICE_NAME}" "${DOCKERFILE}"
fi
