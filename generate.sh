#!/bin/bash
#
# Generates GitHub Actions CI/CD workflows (ghcr.io + Docker Swarm/Traefik on a VPS)

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$KIT_DIR/templates"

source "$KIT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: generate.sh --target <dir> --mode solo|monorepo --domain <host> --port <n> [options]

Required:
  --target <dir>            Repository root to write .github/ into
  --mode solo|monorepo      solo: one app in the repo
                            monorepo: one app per run
  --domain <host>           Production domain (www.<host> redirects to it)
  --port <n>                Production port of the container routed at "/"
                            (frontend: app, backend: server, fullstack: client)

Options:
  --type frontend|backend|fullstack
                            frontend: one container (default)
                            backend: server (+ --db, --migrations-cmd)
                            fullstack: client on "/" + server on --server-path, one stack
  --service <name>          App name, [a-z0-9-] (required for monorepo; solo default: app)
  --pipeline staging|direct staging: staging branch deploys, main promotes its tags (default)
                            direct: main builds and deploys to production
  --staging-domain <host>   Default: staging.<domain>
  --staging-port <n>        Default: <port> + 1
  --extra-path <glob>       Monorepo: extra path that triggers the workflows (repeatable)
                            Fullstack: a change there rebuilds both images (also in solo mode)
  --test-cmd "<cmd>"        Runs after npm ci before building (default: no test step)
  --pr-test-cmd "<cmd>"     Adds a workflow running it after npm ci on pull requests
                            to staging (staging pipeline) or main (direct pipeline)
  --node-version <v>        Node version for the test steps (default: 24)
  --keep-images <n>         ghcr.io image versions to keep (default: 3)
  --force                   Overwrite the app's workflows and stack, and the shared scripts/stack/docs
  -h, --help                Show this help

Frontend:
  --dockerfile <path>       Relative to repo root, build context is the repo root
                            Default: solo tools/docker/Dockerfile, monorepo <app-dir>/tools/docker/Dockerfile
  --app-dir <dir>           Monorepo app folder (default: apps/<service>)

Backend / fullstack:
  --server-dir <dir>        Default: backend solo ".", monorepo apps/<service>
                            fullstack solo apps/server, monorepo apps/<service>-server
  --server-dockerfile <path> Default: <server-dir>/Dockerfile
  --server-replicas <n>     Server replicas, scaled up once the stack is healthy (default: 1)
  --db postgres             Adds a postgres service, DB secrets, backup before deploy, restore on rollback
  --migrations-cmd "<cmd>"  Requires --db: one-shot service running <cmd> (sh -c) in the server image

Fullstack:
  --server-port <n>         Production server port (required)
  --staging-server-port <n> Default: <server-port> + 1
  --server-path <prefix>    Path prefix routed to the server (repeatable, default: /api)
  --client-dir <dir>        Default: solo apps/client, monorepo apps/<service>-client
  --client-dockerfile <path> Default: <client-dir>/Dockerfile
EOF
}

# --- helpers ---

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# "<dir>/Dockerfile", or "Dockerfile" for "."
dockerfile_in() {
  if [ "$1" = "." ]; then
    printf 'Dockerfile'
  else
    printf '%s/Dockerfile' "$1"
  fi
}

# Prints a template, replacing each "__NAME__" line with the BLOCK_NAME env var
# (dropped when empty) and the single-line __TOKENS__.
fill() {
  fill_template "$1" \
    SERVICE_TITLE="$service_title" \
    SERVICE="$service" \
    STAGING_PORT="$staging_port" \
    STAGING_DOMAIN="$staging_domain" \
    PORT="$port" \
    DOMAIN="$domain" \
    DOCKERFILE="$dockerfile" \
    NODE_VERSION="$node_version" \
    KEEP_IMAGES="$keep_images" \
    DB="${db:-none}" \
    SERVER_REPLICAS="$server_replicas" \
    SERVER_RULE="${server_rule:-}" \
    MIGRATIONS_CMD="${migrations_cmd_json:-}" \
    SCP_SOURCES="${scp_sources:-}" \
    CHMOD_DB="${chmod_db:-}" \
    COMPONENTS_JSON="${components_json:-}" \
    APP_MODE="$mode" \
    TEST_BRANCH="$pipeline_branch"
}

# Prints the "paths:" trigger filter of a workflow (monorepo only).
paths_block_for() {
  local workflow_file="$1" p

  [ "$mode" = "monorepo" ] || return 0

  printf '    paths:\n'
  for p in ${trigger_dirs[@]+"${trigger_dirs[@]}"}; do
    if [ "$p" = "." ]; then
      printf '      - "**"\n'
    else
      printf '      - "%s/**"\n' "$p"
    fi
  done
  for p in ${extra_paths[@]+"${extra_paths[@]}"}; do
    printf '      - "%s"\n' "$p"
  done
  if [ "$type" != "frontend" ]; then
    printf '      - ".github/workflows/%s"\n' "$stack_file"
  fi
  printf '      - ".github/workflows/%s"' "$workflow_file"
}

# Succeeds when one of the repo's deploy workflows (see scan_repo_apps) contains $1.
any_workflow() {
  [ ${#deploy_workflows[@]} -gt 0 ] && grep -qF -- "$1" "${deploy_workflows[@]}"
}

# Copies a shared file when $1 is true, otherwise removes a previously generated one.
shared_if() {
  local used="$1" src="$2" dest="$3"

  if $used; then
    copy_shared "$src" "$dest"
  elif [ -e "$dest" ]; then
    rm "$dest"
    rmdir "$(dirname "$dest")" 2>/dev/null || true
    removed+=(".github/${dest#"$github_dir"/}")
  fi
}

# --- options ---

# Sets the options (globals) from the command line, defaults first.
parse_args() {
  target=""
  mode=""
  type="frontend"
  service=""
  pipeline="staging"
  domain=""
  port=""
  staging_domain=""
  staging_port=""
  dockerfile=""
  app_dir=""
  extra_paths=()
  test_cmd=""
  pr_test_cmd=""
  node_version="24"
  keep_images="3"
  force=false
  server_dir=""
  server_dockerfile=""
  server_replicas=""
  db=""
  migrations_cmd=""
  server_port=""
  staging_server_port=""
  server_paths=()
  client_dir=""
  client_dockerfile=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --target) need_value "$@"; target="$2"; shift 2 ;;
      --mode) need_value "$@"; mode="$2"; shift 2 ;;
      --type) need_value "$@"; type="$2"; shift 2 ;;
      --service) need_value "$@"; service="$2"; shift 2 ;;
      --pipeline) need_value "$@"; pipeline="$2"; shift 2 ;;
      --domain) need_value "$@"; domain="$2"; shift 2 ;;
      --port) need_value "$@"; port="$2"; shift 2 ;;
      --staging-domain) need_value "$@"; staging_domain="$2"; shift 2 ;;
      --staging-port) need_value "$@"; staging_port="$2"; shift 2 ;;
      --dockerfile) need_value "$@"; dockerfile="$2"; shift 2 ;;
      --app-dir) need_value "$@"; app_dir="$2"; shift 2 ;;
      --extra-path) need_value "$@"; extra_paths+=("$2"); shift 2 ;;
      --test-cmd) need_value "$@"; test_cmd="$2"; shift 2 ;;
      --pr-test-cmd) need_value "$@"; pr_test_cmd="$2"; shift 2 ;;
      --node-version) need_value "$@"; node_version="$2"; shift 2 ;;
      --keep-images) need_value "$@"; keep_images="$2"; shift 2 ;;
      --server-dir) need_value "$@"; server_dir="$2"; shift 2 ;;
      --server-dockerfile) need_value "$@"; server_dockerfile="$2"; shift 2 ;;
      --server-replicas) need_value "$@"; server_replicas="$2"; shift 2 ;;
      --db) need_value "$@"; db="$2"; shift 2 ;;
      --migrations-cmd) need_value "$@"; migrations_cmd="$2"; shift 2 ;;
      --server-port) need_value "$@"; server_port="$2"; shift 2 ;;
      --staging-server-port) need_value "$@"; staging_server_port="$2"; shift 2 ;;
      --server-path) need_value "$@"; server_paths+=("$2"); shift 2 ;;
      --client-dir) need_value "$@"; client_dir="$2"; shift 2 ;;
      --client-dockerfile) need_value "$@"; client_dockerfile="$2"; shift 2 ;;
      --force) force=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown argument '$1'" ;;
    esac
  done
}

# Checks the options and resolves their defaults (service, server_replicas, server_paths, staging).
validate_args() {
  validate_target
  validate_mode
  [ "$type" = "frontend" ] || [ "$type" = "backend" ] || [ "$type" = "fullstack" ] || fail "--type must be frontend, backend or fullstack"
  [ "$pipeline" = "staging" ] || [ "$pipeline" = "direct" ] || fail "--pipeline must be staging or direct"
  [ -n "$domain" ] || fail "--domain is required"
  [ -n "$port" ] || fail "--port is required"

  validate_service
  validate_values
  validate_type_options
  validate_fullstack_options
  resolve_staging_options
}

# Checks --service (default: app in solo mode) and the options that only apply to monorepos.
validate_service() {
  if [ "$mode" = "monorepo" ]; then
    [ -n "$service" ] || fail "--service is required in monorepo mode"
  else
    [ -n "$service" ] || service="app"
    if [ "$type" != "fullstack" ]; then
      [ ${#extra_paths[@]} -eq 0 ] || fail "--extra-path only applies to monorepo mode or fullstack apps (solo workflows run on every push)"
    fi
    [ -z "$app_dir" ] || fail "--app-dir only applies to monorepo mode"
  fi

  [[ "$service" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "--service must match [a-z0-9-] (no leading/trailing dash)"
  # stacks/<service>.yml would replace the shared stacks/stack.yml
  [ "$service" != "stack" ] || fail "--service can't be 'stack'"
  # deploy-<service>.yml would read as another app's deploy-staging-*/deploy-production-*.yml
  case "$service" in
    staging-*|production-*) fail "--service can't start with 'staging-' or 'production-'" ;;
  esac
}

# Checks the port, domain, image count and Node version values.
validate_values() {
  is_port "$port" || fail "--port must be a number between 1 and 65535"
  is_domain "$domain" || fail "--domain '$domain' is not a valid host name"
  [[ "$keep_images" =~ ^[0-9]+$ ]] && [ "$keep_images" -ge 1 ] || fail "--keep-images must be a positive number"
  [[ "$node_version" =~ ^[A-Za-z0-9.*/_-]+$ ]] || fail "--node-version '$node_version' is not valid"
}

# Checks the frontend vs backend/fullstack options, defaults server_replicas to 1.
validate_type_options() {
  local flag

  if [ "$type" = "frontend" ]; then
    for flag in server_dir server_dockerfile server_replicas db migrations_cmd; do
      [ -z "${!flag}" ] || fail "--${flag//_/-} only applies to backend and fullstack apps"
    done
  else
    [ -z "$dockerfile" ] || fail "--dockerfile only applies to frontend apps (use --server-dockerfile/--client-dockerfile)"
    [ -z "$app_dir" ] || fail "--app-dir only applies to frontend apps (use --server-dir/--client-dir)"
    [ -z "$db" ] || [ "$db" = "postgres" ] || fail "--db must be postgres"
    [ -z "$migrations_cmd" ] || [ "$db" = "postgres" ] || fail "--migrations-cmd requires --db postgres"
    # "$" would be replaced by envsubst when the stack file is generated in CI
    [[ "$migrations_cmd" != *'$'* ]] || fail "--migrations-cmd can't contain '\$'"
    [[ "$migrations_cmd" != *$'\n'* ]] || fail "--migrations-cmd must be a single line"
    [ -n "$server_replicas" ] || server_replicas="1"
    [[ "$server_replicas" =~ ^[0-9]+$ ]] && [ "$server_replicas" -ge 1 ] || fail "--server-replicas must be a positive number"
  fi
}

# Checks the fullstack-only options, defaults server_paths to /api.
validate_fullstack_options() {
  local flag p

  if [ "$type" != "fullstack" ]; then
    for flag in server_port staging_server_port client_dir client_dockerfile; do
      [ -z "${!flag}" ] || fail "--${flag//_/-} only applies to fullstack apps"
    done
    [ ${#server_paths[@]} -eq 0 ] || fail "--server-path only applies to fullstack apps"
  else
    [ -n "$server_port" ] || fail "--server-port is required for fullstack apps"
    is_port "$server_port" || fail "--server-port must be a number between 1 and 65535"
    [ "$server_port" != "$port" ] || fail "--server-port must differ from --port"
    [ ${#server_paths[@]} -gt 0 ] || server_paths=("/api")
    for p in "${server_paths[@]}"; do
      [[ "$p" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "--server-path '$p' must start with / and can't be / (the client is served there)"
    done
  fi
}

# Staging pipeline: defaults and checks staging_domain/staging_port/staging_server_port.
# Direct pipeline: refuses them.
resolve_staging_options() {
  if [ "$pipeline" = "staging" ]; then
    [ -n "$staging_domain" ] || staging_domain="staging.$domain"
    [ -n "$staging_port" ] || staging_port=$((port + 1))
    is_port "$staging_port" || fail "--staging-port must be a number between 1 and 65535"
    is_domain "$staging_domain" || fail "--staging-domain '$staging_domain' is not a valid host name"
    [ "$staging_port" != "$port" ] || fail "--staging-port must differ from --port"
    [ "$staging_domain" != "$domain" ] || fail "--staging-domain must differ from --domain"
    if [ "$type" = "fullstack" ]; then
      [ -n "$staging_server_port" ] || staging_server_port=$((server_port + 1))
      is_port "$staging_server_port" || fail "--staging-server-port must be a number between 1 and 65535"
      [ "$staging_server_port" != "$staging_port" ] || fail "--staging-server-port must differ from --staging-port"
    fi
  elif [ -n "$staging_domain" ] || [ -n "$staging_port" ] || [ -n "$staging_server_port" ]; then
    fail "--staging-domain/--staging-port/--staging-server-port only apply to the staging pipeline"
  fi
}

# Sets the app's dirs and Dockerfiles (defaults by type and mode), trigger_dirs
# For backend/fullstack: components ("name:dockerfile"), all_components ("name:dockerfile:dir") and components_json.
resolve_app_layout() {
  local default_server_dir default_client_dir p

  case "$type" in
    frontend)
      if [ "$mode" = "monorepo" ]; then
        [ -n "$app_dir" ] || app_dir="apps/$service"
        app_dir="$(normalize_dir "$app_dir")"
        [ -n "$dockerfile" ] || dockerfile="$app_dir/tools/docker/Dockerfile"
      else
        [ -n "$dockerfile" ] || dockerfile="tools/docker/Dockerfile"
      fi
      dockerfile="${dockerfile#./}"
      is_path "$dockerfile" || fail "--dockerfile '$dockerfile' contains unsupported characters"
      trigger_dirs=(${app_dir:+"$app_dir"})
      ;;
    backend|fullstack)
      if [ "$type" = "backend" ]; then
        [ "$mode" = "monorepo" ] && default_server_dir="apps/$service" || default_server_dir="."
      else
        [ "$mode" = "monorepo" ] && default_server_dir="apps/$service-server" || default_server_dir="apps/server"
        [ "$mode" = "monorepo" ] && default_client_dir="apps/$service-client" || default_client_dir="apps/client"
      fi
      server_dir="$(normalize_dir "${server_dir:-$default_server_dir}")"
      [ -n "$server_dockerfile" ] || server_dockerfile="$(dockerfile_in "$server_dir")"
      server_dockerfile="${server_dockerfile#./}"
      is_path "$server_dir" || fail "--server-dir '$server_dir' contains unsupported characters"
      is_path "$server_dockerfile" || fail "--server-dockerfile '$server_dockerfile' contains unsupported characters"
      trigger_dirs=("$server_dir")
      components="server:$server_dockerfile"
      all_components="server:$server_dockerfile:$server_dir"
      components_json='["server"]'

      if [ "$type" = "fullstack" ]; then
        client_dir="$(normalize_dir "${client_dir:-$default_client_dir}")"
        [ -n "$client_dockerfile" ] || client_dockerfile="$(dockerfile_in "$client_dir")"
        client_dockerfile="${client_dockerfile#./}"
        is_path "$client_dir" || fail "--client-dir '$client_dir' contains unsupported characters"
        is_path "$client_dockerfile" || fail "--client-dockerfile '$client_dockerfile' contains unsupported characters"
        [ "$client_dir" != "$server_dir" ] || fail "--client-dir must differ from --server-dir"
        trigger_dirs+=("$client_dir")
        components="$components,client:$client_dockerfile"
        all_components="$all_components,client:$client_dockerfile:$client_dir"
        components_json='["server", "client"]'
      fi
      ;;
  esac

  for p in ${extra_paths[@]+"${extra_paths[@]}"}; do
    [[ "$p" != *[\",]* ]] || fail "--extra-path '$p' can't contain '\"' or ','"
  done
}

# Sets service_title, github_dir, workflows_dir, the app's file names and pipeline_branch.
resolve_file_names() {
  service_title="$(capitalize "$service")"

  github_dir="$target_dir/.github"
  workflows_dir="$github_dir/workflows"

  if [ "$mode" = "monorepo" ]; then
    staging_file="deploy-staging-$service.yml"
    production_file="deploy-production-$service.yml"
    direct_file="deploy-$service.yml"
    test_file="test-$service.yml"
  else
    staging_file="deploy-staging.yml"
    production_file="deploy-production.yml"
    direct_file="deploy.yml"
    test_file="test.yml"
  fi
  # backend/fullstack only, but always checked so --force can switch an app back to frontend
  stack_file="stacks/$service.yml"

  [ "$pipeline" = "staging" ] && pipeline_branch="staging" || pipeline_branch="main"
}

# --- per-app files ---

# Exits when the app's files exist, unless --force:, then removes them
remove_previous_app_files() {
  local f
  local existing=()

  for f in "$staging_file" "$production_file" "$direct_file" "$test_file" "$stack_file"; do
    [ -e "$workflows_dir/$f" ] && existing+=("$f")
  done

  [ ${#existing[@]} -gt 0 ] || return 0

  if ! $force; then
    echo "Error: files for '$service' already exist in $workflows_dir:" >&2
    printf '  %s\n' "${existing[@]}" >&2
    echo "Re-run with --force to overwrite them." >&2
    exit 1
  fi
  for f in "${existing[@]}"; do
    rm "$workflows_dir/$f"
    removed+=(".github/workflows/$f")
  done
}

# Warns about ports already used by another app's stack: Traefik would route to the wrong service.
warn_port_clashes() {
  local p clashes

  [ -d "$workflows_dir" ] || return 0

  for p in "$port" ${staging_port:+"$staging_port"} ${server_port:+"$server_port"} ${staging_server_port:+"$staging_server_port"}; do
    clashes="$(grep -lE "(CLIENT|SERVER)_PORT: \"$p\"" "$workflows_dir"/*.yml 2>/dev/null || true)"
    if [ -n "$clashes" ]; then
      echo "Warning: port $p is already used in:" >&2
      printf '%s\n' "$clashes" | sed 's|^|  |' >&2
    fi
  done
}

# Exports the workflow template blocks: BLOCK_TEST_STEP, BLOCK_PATHS, and the backend/fullstack ones.
build_workflow_blocks() {
  export BLOCK_TEST_STEP=""
  if [ -n "$test_cmd" ]; then
    BLOCK_TEST_STEP="$(
      printf '      - name: Set up Node.js\n'
      printf '        uses: actions/setup-node@v7\n'
      printf '        with:\n'
      printf '          node-version: "__NODE_VERSION__"\n'
      printf '          cache: "npm"\n\n'
      printf '      - name: Install dependencies\n'
      printf '        run: npm ci\n\n'
      printf '      - name: Run tests\n'
      run_block '        ' "$test_cmd"
      printf '\n'
    )"$'\n'
  fi

  # set per workflow by write_app_workflows
  export BLOCK_PATHS=""

  [ "$type" = "frontend" ] || build_stack_workflow_blocks
}

# Backend/fullstack: exports BLOCK_COMPONENTS_STEP and BLOCK_PORTS(_STAGING), sets scp_sources and chmod_db.
build_stack_workflow_blocks() {
  local shared_paths

  # only fullstack staging builds pick what changed, see get-changed-components.sh
  if [ "$type" = "fullstack" ] && [ "$pipeline" = "staging" ]; then
    shared_paths="$(IFS=','; echo "${extra_paths[*]+"${extra_paths[*]}"}")"
    export BLOCK_COMPONENTS_STEP="$(
      printf '      - name: Get changed components\n'
      printf '        id: get_components\n'
      printf '        run: .github/workflows/scripts/jobs/get-changed-components.sh\n'
      printf '        env:\n'
      printf '          ALL_COMPONENTS: "%s"\n' "$all_components"
      printf '          SHARED_PATHS: "%s"\n' "$shared_paths"
      printf '\n'
    )"$'\n'
  else
    export BLOCK_COMPONENTS_STEP="$(
      printf '      - name: Set components to build\n'
      printf '        id: get_components\n'
      printf '        run: echo "components=%s" >> $GITHUB_OUTPUT\n' "$components"
      printf '\n'
    )"$'\n'
  fi

  if [ "$type" = "fullstack" ]; then
    export BLOCK_PORTS="$(printf '      CLIENT_PORT: "%s"\n      SERVER_PORT: "%s"' "$port" "$server_port")"
    export BLOCK_PORTS_STAGING="$(printf '      CLIENT_PORT: "%s"\n      SERVER_PORT: "%s"' "$staging_port" "$staging_server_port")"
  else
    export BLOCK_PORTS="$(printf '      SERVER_PORT: "%s"' "$port")"
    export BLOCK_PORTS_STAGING="$(printf '      SERVER_PORT: "%s"' "$staging_port")"
  fi

  scp_sources=".github/workflows/scripts/deployment/*.sh"
  chmod_db=""
  if [ -n "$db" ]; then
    scp_sources="$scp_sources,.github/workflows/scripts/db-backup/*.sh"
    chmod_db=" scripts/db-backup/*.sh"
  fi
}

# Writes the app's deploy workflows (staging + production, or direct) and its PR test workflow.
write_app_workflows() {
  local workflow_templates="$TEMPLATES/workflows"

  [ "$type" = "frontend" ] || workflow_templates="$TEMPLATES/workflows/stack"

  if [ "$pipeline" = "staging" ]; then
    BLOCK_PATHS="$(paths_block_for "$staging_file")"
    write_file "$workflows_dir/$staging_file" fill "$workflow_templates/deploy-staging.yml"
    BLOCK_PATHS="$(paths_block_for "$production_file")"
    write_file "$workflows_dir/$production_file" fill "$workflow_templates/deploy-production.yml"
  else
    BLOCK_PATHS="$(paths_block_for "$direct_file")"
    write_file "$workflows_dir/$direct_file" fill "$workflow_templates/deploy-direct.yml"
  fi

  if [ -n "$pr_test_cmd" ]; then
    BLOCK_PATHS="$(paths_block_for "$test_file")"
    export BLOCK_PR_TEST_CMD="$(printf '%s\n' "$pr_test_cmd" | sed 's|^|          |')"
    write_file "$workflows_dir/$test_file" fill "$TEMPLATES/workflows/pr-tests.yml"
  fi
}

# Backend/fullstack: writes stacks/<service>.yml from the fragments, sets server_rule and migrations_cmd_json.
write_stack_file() {
  local fragments="$TEMPLATES/stacks/fragments" middleware_labels p

  [ "$type" != "frontend" ] || return 0

  if [ "$type" = "fullstack" ]; then
    server_rule=""
    for p in "${server_paths[@]}"; do
      server_rule="${server_rule:+$server_rule || }PathPrefix(\`$p\`)"
    done
    [ ${#server_paths[@]} -eq 1 ] || server_rule="($server_rule)"
  else
    server_rule="PathPrefix(\`/\`)"
  fi

  # JSON string inside the YAML flow sequence
  migrations_cmd_json="$(printf '%s' "$migrations_cmd" | sed -e 's/[\\"]/\\&/g')"

  middleware_labels="$(cat "$fragments/middleware-labels.yml")"
  export BLOCK_DB_ENV="" BLOCK_DB_SECRETS="" BLOCK_MIDDLEWARE_LABELS=""
  if [ -n "$db" ]; then
    BLOCK_DB_ENV="$(cat "$fragments/db-env.yml")"
    BLOCK_DB_SECRETS="$(cat "$fragments/db-secrets.yml")"
  fi

  write_file "$workflows_dir/$stack_file" print_stack_file "$fragments" "$middleware_labels"
}

# Prints the stack file: print_stack_file <fragments dir> <middleware labels>
print_stack_file() {
  local fragments="$1" middleware_labels="$2"

  echo "services:"
  # the www redirect + HSTS middlewares are defined on the service routed at "/"
  if [ "$type" = "fullstack" ]; then
    BLOCK_MIDDLEWARE_LABELS="$middleware_labels" fill "$fragments/client.yml"
    fill "$fragments/server.yml"
  else
    BLOCK_MIDDLEWARE_LABELS="$middleware_labels" fill "$fragments/server.yml"
  fi
  [ -z "$migrations_cmd" ] || fill "$fragments/migrations.yml"
  [ -z "$db" ] || fill "$fragments/postgres.yml"
  fill "$fragments/networks.yml"
  [ -z "$db" ] || fill "$fragments/db-tail.yml"
}

# --- shared files ---

# Sets what the repo's apps use: deploy_workflows, production_names (staging-pipeline apps), has_staging, and uses_* flags.
scan_repo_apps() {
  local f name

  production_names=()
  for f in "$workflows_dir"/deploy-production.yml "$workflows_dir"/deploy-production-*.yml; do
    [ -f "$f" ] || continue
    name="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -n 1)"
    [ -n "$name" ] && production_names+=("$name")
  done

  deploy_workflows=()
  for f in "$workflows_dir"/deploy*.yml; do
    [ -f "$f" ] && deploy_workflows+=("$f")
  done

  [ ${#production_names[@]} -gt 0 ] && has_staging=true || has_staging=false
  any_workflow "get-changed-components.sh" && uses_components=true || uses_components=false
  # only backend/fullstack workflows set SERVER_REPLICAS
  any_workflow "SERVER_REPLICAS:" && uses_stack=true || uses_stack=false
  any_workflow 'DB: "postgres"' && uses_db=true || uses_db=false
  uses_shared_stack=false
  if [ ${#deploy_workflows[@]} -gt 0 ] && [ -n "$(grep -LF "SERVER_REPLICAS:" "${deploy_workflows[@]}")" ]; then
    uses_shared_stack=true
  fi
}

# Copies the shared scripts, stack, workflows and docs the repo's app(s) use, removes the others, writes .env.dist.
write_shared_files() {
  local src script used

  scan_repo_apps

  for src in "$TEMPLATES"/scripts/jobs/*.sh "$TEMPLATES"/scripts/deployment/*.sh "$TEMPLATES"/scripts/db-backup/*.sh; do
    script="${src#"$TEMPLATES"/scripts/}"
    case "$script" in
      deployment/remove-staging.sh|jobs/recreate-staging.sh) used=$has_staging ;;
      jobs/get-changed-components.sh) used=$uses_components ;;
      deployment/scale-backend.sh) used=$uses_stack ;;
      db-backup/*) used=$uses_db ;;
      *) used=true ;;
    esac
    shared_if "$used" "$src" "$workflows_dir/scripts/$script"
  done
  shared_if "$uses_shared_stack" "$TEMPLATES/stacks/stack.yml" "$workflows_dir/stacks/stack.yml"
  shared_if "$has_staging" "$TEMPLATES/workflows/restrict-main-pr.yml" "$workflows_dir/restrict-main-pr.yml"
  copy_shared "$TEMPLATES/docs/WORKFLOWS.md" "$github_dir/docs/WORKFLOWS.md"

  write_recreate_staging
  write_env_dist
}

# Writes recreate-staging.yml, listing every staging-pipeline app's production workflow (so it's always rebuilt),
# or removes it when there's none.
write_recreate_staging() {
  if $has_staging; then
    export BLOCK_WORKFLOWS="$(printf '      - "%s"\n' "${production_names[@]}")"
    write_file "$workflows_dir/recreate-staging.yml" fill "$TEMPLATES/workflows/recreate-staging.yml"
  elif [ -e "$workflows_dir/recreate-staging.yml" ]; then
    rm "$workflows_dir/recreate-staging.yml"
    removed+=(".github/workflows/recreate-staging.yml")
  fi
}

# --- summary ---

# Prints the URL and port(s) of a stack: route_line <host> <port> <server port>
route_line() {
  local host="$1" main_port="$2" api_port="$3"

  case "$type" in
    frontend) echo "https://$host (port $main_port)" ;;
    backend) echo "https://$host → server (port $main_port)" ;;
    fullstack) echo "https://$host → client (port $main_port), ${server_paths[*]} → server (port $api_port)" ;;
  esac
}

# Prints the production (and staging) routes.
print_routes() {
  echo "Production: $(route_line "$domain" "$port" "$server_port")"
  if [ "$pipeline" = "staging" ]; then
    echo "Staging:    $(route_line "$staging_domain" "$staging_port" "$staging_server_port")"
  fi
}

# Prints the GitHub, VPS and DNS setup the app needs.
print_next_steps() {
  local health

  case "$type" in
    frontend) health="Dockerfile at '$dockerfile' must serve" ;;
    backend) health="Server image ('$server_dockerfile') must serve" ;;
    fullstack) health="Client ('$client_dockerfile') and server ('$server_dockerfile') images must serve" ;;
  esac

  cat <<EOF

Next steps:
  - GitHub secrets (names in .env.dist): SSH_HOST, SSH_USER, SSH_PRIVATE_KEY, SSH_PASS, SSH_PORT, SSH_FINGERPRINT, DOCKER_AUTH${db:+, ENCRYPTION_PASSWORD (database backups)}
    (DOCKER_AUTH = printf '%s' 'username:PAT' | base64 | tr -d '\n', classic PAT with read:packages only)
    (SSH_FINGERPRINT = the "SHA256:…" of ssh-keyscan -t ed25519 -p <port> <host> | ssh-keygen -lf -)
  - VPS: Docker Swarm + Traefik on the external 'traefik-public' network, flock (util-linux) to queue the deploys
  - $health GET /health on their port (healthcheck uses wget)
  - DNS: $domain and www.$domain${staging_domain:+, $staging_domain and www.$staging_domain} → VPS
EOF
  if [ "$pipeline" = "staging" ]; then
    echo "  - Create a 'staging' branch; PRs to main must come from it"
  fi
  [ -z "$db" ] || print_db_secrets_steps
  if [ "$type" != "frontend" ]; then
    echo "  - Add app-specific env/secrets to .github/workflows/$stack_file (kept on re-runs without --force)"
  fi
}

# Prints the Docker secrets and backup dir to create on the VPS for the database.
print_db_secrets_steps() {
  local project secret_prefix stacks stack secret

  project="$(basename "$(dirname "$github_dir")" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  # solo: the repo is the app, so secret names drop the service (see format-name.sh)
  [ "$mode" = "solo" ] && secret_prefix="$project" || secret_prefix="${project}_$service"
  stacks="production"
  [ "$pipeline" = "staging" ] && stacks="staging production"
  echo "  - VPS Docker secrets, <project> = lowercased GitHub repo name (here assumed '$project'):"
  for stack in $stacks; do
    for secret in db_user db_password db_name; do
      echo "      echo \"...\" | docker secret create ${secret_prefix}_${stack}_${secret} -"
    done
  done
  echo "  - VPS: /backups writable by the SSH user (or set BACKUP_DIR), backups are kept 7 days"
}

# Prints the written files, the routes and the next steps.
print_summary() {
  echo "Generated $pipeline pipeline for $type app '$service' ($mode) in $github_dir"
  echo
  print_files
  echo
  print_routes
  print_next_steps
}

main() {
  parse_args "$@"
  validate_args
  resolve_app_layout
  resolve_file_names
  remove_previous_app_files
  warn_port_clashes
  build_workflow_blocks
  write_app_workflows
  write_stack_file
  write_shared_files
  print_summary
}

main "$@"
