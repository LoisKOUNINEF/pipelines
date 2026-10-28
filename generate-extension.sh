#!/bin/bash
#
# Generates GitHub Actions workflows checking, packaging and releasing a browser extension
# (GitHub Release, Chrome Web Store, Firefox Add-ons) on tag push

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$KIT_DIR/templates"

source "$KIT_DIR/lib/common.sh"

DEFAULT_PACKAGE_CMD='npm run "package:extension:$BROWSER"'
DEFAULT_VALIDATE_CMD='node tools/extension/validate-extension.js --browser "$BROWSER" ${TAG:+--tag "$TAG"}'
DEFAULT_LINT_CMD='npm run lint:extension'

usage() {
  cat <<'EOF'
Usage: generate-extension.sh --target <dir> [options]

Required:
  --target <dir>            Repository root to write .github/ into (the extension is the repo root,
                            with a package.json and a .nvmrc)

Options:
  --name <name>             Prefix of the packaged ZIPs (<name>-<browser>-<version>.zip) and of the
                            workflow artifacts (default: package.json "name")
  --title <title>           Release title, "<title> vX.Y.Z" (default: --name, capitalized)
  --browser chrome|firefox  Browser to build (repeatable, default: both)
  --check "<cmd>"           Step of the check job, run after npm ci (repeatable, in order)
                            (default: "npm run build -- -y", "npm run testin-nutin:only")
  --package-cmd "<cmd>"     Packages one browser, $BROWSER set
                            (default: npm run "package:extension:$BROWSER")
  --validate-cmd "<cmd>"    Validates the package, $BROWSER and $TAG set, "" to skip
                            (default: node tools/extension/validate-extension.js --browser "$BROWSER" ${TAG:+--tag "$TAG"})
  --lint-cmd "<cmd>"        Lints the Firefox build, "" to skip (default: npm run lint:extension)
  --no-chrome-store         Don't submit to the Chrome Web Store
  --no-firefox-store        Don't submit to Firefox Add-ons
  --no-source-archive       Don't upload a source archive to Firefox Add-ons
                            (only for builds AMO reviewers can read as-is: not minified nor bundled)
  --force                   Overwrite the workflows, the build action and the shared files
  -h, --help                Show this help
EOF
}

# --- helpers ---

# Prints a template with the extension's __TOKENS__ replaced.
render() {
  fill_template "$1" \
    NAME="$name" \
    TITLE="$title" \
    CHECK_JOB_NAME="$check_job_name" \
    BROWSERS="$browser_list"
}

# --- steps ---

# Sets the options (globals) from the command line, defaults first.
parse_args() {
  target=""
  name=""
  title=""
  browsers=()
  checks=()
  package_cmd="$DEFAULT_PACKAGE_CMD"
  validate_cmd="$DEFAULT_VALIDATE_CMD"
  lint_cmd="$DEFAULT_LINT_CMD"
  chrome_store=true
  firefox_store=true
  source_archive=true
  force=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --target) need_value "$@"; target="$2"; shift 2 ;;
      --name) need_value "$@"; name="$2"; shift 2 ;;
      --title) need_value "$@"; title="$2"; shift 2 ;;
      --browser) need_value "$@"; browsers+=("$2"); shift 2 ;;
      --check) need_value "$@"; checks+=("$2"); shift 2 ;;
      --package-cmd) need_value "$@"; package_cmd="$2"; shift 2 ;;
      # may be empty: the step is dropped
      --validate-cmd) [ $# -ge 2 ] || fail "$1 requires a value"; validate_cmd="$2"; shift 2 ;;
      --lint-cmd) [ $# -ge 2 ] || fail "$1 requires a value"; lint_cmd="$2"; shift 2 ;;
      --no-chrome-store) chrome_store=false; shift ;;
      --no-firefox-store) firefox_store=false; shift ;;
      --no-source-archive) source_archive=false; shift ;;
      --force) force=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown argument '$1'" ;;
    esac
  done
}

# Checks the target repo and the options, and resolves their defaults.
validate_args() {
  validate_target

  [ -f "$target_dir/package.json" ] || fail "no package.json in '$target_dir'"
  [ -f "$target_dir/.nvmrc" ] || fail "no .nvmrc in '$target_dir' (the workflows read the Node version from it)"
  [ -f "$target_dir/package-lock.json" ] || fail "no package-lock.json in '$target_dir' (the workflows install with npm ci)"

  resolve_name_and_title
  resolve_browsers
  resolve_checks
}

# Sets name (default: package.json "name") and title (default: name, capitalized).
resolve_name_and_title() {
  if [ -z "$name" ]; then
    command -v node > /dev/null || fail "node is needed to read the package.json name: install it or pass --name"
    name="$(package_json_name "$target_dir/package.json")"
    [ -n "$name" ] || fail "package.json has no \"name\": pass --name"
  fi
  # no glob characters nor "/": the name is used in file globs and artifact names
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--name '$name' can only contain letters, digits, '.', '_' and '-' (scoped package? pass --name)"

  [ -n "$title" ] || title="$(capitalize "$name")"
  # inside a double-quoted shell string
  [[ "$title" =~ ^[A-Za-z0-9\ ._-]+$ ]] || fail "--title '$title' can only contain letters, digits, spaces, '.', '_' and '-'"
}

# Sets browsers (deduplicated, chrome first), browser_list, has_chrome/has_firefox, and turns off
# the stores, source archive and lint of the browsers not built.
resolve_browsers() {
  local browser

  [ ${#browsers[@]} -gt 0 ] || browsers=(chrome firefox)
  has_chrome=false
  has_firefox=false
  for browser in "${browsers[@]}"; do
    case "$browser" in
      chrome) has_chrome=true ;;
      firefox) has_firefox=true ;;
      *) fail "--browser must be chrome or firefox, got '$browser'" ;;
    esac
  done
  # deduplicated, always in the same order
  browsers=()
  $has_chrome && browsers+=(chrome)
  $has_firefox && browsers+=(firefox)
  browser_list="$(IFS=,; printf '%s' "${browsers[*]}" | sed 's/,/, /g')"

  $has_chrome || chrome_store=false
  $has_firefox || firefox_store=false
  # the source archive is only uploaded to Firefox Add-ons
  $firefox_store || source_archive=false
  $has_firefox || lint_cmd=""
}

# Sets checks (default: build + unit tests), default_checks and check_job_name.
resolve_checks() {
  default_checks=false
  if [ ${#checks[@]} -eq 0 ]; then
    default_checks=true
    checks=("npm run build -- -y" "npm run testin-nutin:only")
  fi

  check_job_name="Checks"
  $default_checks && check_job_name="Typecheck · tests"
  return 0
}

# Sets github_dir, workflows_dir and action_file.
resolve_file_names() {
  github_dir="$target_dir/.github"
  workflows_dir="$github_dir/workflows"
  action_file="$github_dir/actions/build-extension/action.yml"
}

# Exports the template blocks: the check steps, the commands and the optional steps.
build_blocks() {
  local i check step_name

  export BLOCK_CHECK_STEPS
  BLOCK_CHECK_STEPS="$(
    for i in "${!checks[@]}"; do
      check="${checks[$i]}"
      if $default_checks; then
        [ "$i" -eq 0 ] && step_name="Typecheck (build)" || step_name="Unit tests"
      else
        step_name="$(yaml_title "Run $check")"
      fi
      printf '\n      - name: %s\n' "$step_name"
      run_block '        ' "$check"
    done
  )"$'\n'

  export BLOCK_PACKAGE_CMD="$package_cmd" BLOCK_VALIDATE_CMD="$validate_cmd" BLOCK_LINT_CMD="$lint_cmd"

  # optional steps, each followed by a blank line
  export BLOCK_VALIDATE_STEP="" BLOCK_LINT_STEP="" BLOCK_SOURCE_ARCHIVE_STEP="" BLOCK_SOURCE_CODE_ARG=""
  [ -z "$validate_cmd" ] || BLOCK_VALIDATE_STEP="$(expand_blocks "$TEMPLATES/actions/build-extension/validate.yml")"$'\n'
  [ -z "$lint_cmd" ] || BLOCK_LINT_STEP="$(expand_blocks "$TEMPLATES/actions/build-extension/lint.yml")"$'\n'
  if $source_archive; then
    BLOCK_SOURCE_ARCHIVE_STEP="$(expand_blocks "$TEMPLATES/workflows/extension/source-archive.yml")"$'\n'
    BLOCK_SOURCE_CODE_ARG='--upload-source-code "dist/__NAME__-source-${TAG#v}.zip" \'
  fi
}

# Prints release.yml, ended by the store jobs.
print_release_workflow() {
  render "$TEMPLATES/workflows/extension/release.yml"
  ! $chrome_store || render "$TEMPLATES/workflows/extension/chrome-web-store.yml"
  ! $firefox_store || render "$TEMPLATES/workflows/extension/firefox-addons.yml"
}

# Writes ci.yml, release.yml, the build action and the shared files.
write_files() {
  write_file "$workflows_dir/ci.yml" render "$TEMPLATES/workflows/extension/ci.yml"
  write_file "$workflows_dir/release.yml" print_release_workflow
  write_file "$action_file" render "$TEMPLATES/actions/build-extension/action.yml"

  copy_shared "$TEMPLATES/dependabot.yml" "$github_dir/dependabot.yml"
  copy_shared "$TEMPLATES/docs/EXTENSIONS.md" "$github_dir/docs/EXTENSIONS.md"
}

# Prints the written files, how to release and the store setup.
print_summary() {
  echo "Generated extension workflows for '$name' (${browsers[*]}) in $github_dir"
  echo
  print_files

  echo
  echo "Release: bump the version in package.json, then git tag vX.Y.Z && git push origin vX.Y.Z"
  if $chrome_store || $firefox_store; then
    echo
    echo "Next steps:"
    echo "  - GitHub: Settings → Environments → create 'store' (add required reviewers to approve each submission)"
    $chrome_store && echo "  - 'store' secrets: CWS_CLIENT_ID, CWS_CLIENT_SECRET, CWS_REFRESH_TOKEN, CWS_PUBLISHER_ID, CWS_EXTENSION_ID"
    $firefox_store && echo "  - 'store' secrets: AMO_JWT_ISSUER, AMO_JWT_SECRET (and keep web-ext in the devDependencies)"
  fi
  # the last "$x && echo" may be false
  return 0
}

main() {
  parse_args "$@"
  validate_args
  resolve_file_names
  refuse_existing "$workflows_dir/ci.yml" "$workflows_dir/release.yml" "$action_file"
  build_blocks
  write_files
  print_summary
}

main "$@"
