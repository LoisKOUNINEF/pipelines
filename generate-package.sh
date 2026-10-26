#!/bin/bash
#
# Generates a GitHub Actions workflow publishing an npm package (trusted publishing) on tag push

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$KIT_DIR/templates"

source "$KIT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: generate-package.sh --target <dir> --mode solo|monorepo [options]

Required:
  --target <dir>            Repository root to write .github/ into
  --mode solo|monorepo      solo: the package is the repo root
                            monorepo: one package per run, in --package-dir

Options:
  --package-dir <dir>       Package folder, relative to the repo root (required for monorepo; solo: .)
  --name <slug>             [a-z0-9-], names the workflow, its file (monorepo) and concurrency group
                            (default: solo package.json "name" as a slug, monorepo basename of --package-dir)
  --tag-prefix <prefix>     Tags publishing the package: <prefix><version>
                            (default: solo v, monorepo <name>-v)
  --check "<cmd>"           Pre-publish step run in the package dir after npm ci (repeatable, in order)
  --node-version <v>        Default: 24
  --skip-main-check         Publish tags that aren't on main too
  --force                   Overwrite the package's workflow and the shared docs
  -h, --help                Show this help
EOF
}

target=""
mode=""
package_dir=""
name=""
tag_prefix=""
checks=()
node_version="24"
main_check=true
force=false

while [ $# -gt 0 ]; do
  case "$1" in
    --target) need_value "$@"; target="$2"; shift 2 ;;
    --mode) need_value "$@"; mode="$2"; shift 2 ;;
    --package-dir) need_value "$@"; package_dir="$2"; shift 2 ;;
    --name) need_value "$@"; name="$2"; shift 2 ;;
    --tag-prefix) need_value "$@"; tag_prefix="$2"; shift 2 ;;
    --check) need_value "$@"; checks+=("$2"); shift 2 ;;
    --node-version) need_value "$@"; node_version="$2"; shift 2 ;;
    --skip-main-check) main_check=false; shift ;;
    --force) force=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument '$1'" ;;
  esac
done

# --- validation ---

[ -n "$target" ] || fail "--target is required"
[ -d "$target" ] || fail "--target '$target' is not a directory"
[ -n "$mode" ] || fail "--mode is required (solo or monorepo)"
[ "$mode" = "solo" ] || [ "$mode" = "monorepo" ] || fail "--mode must be solo or monorepo"
[[ "$node_version" =~ ^[A-Za-z0-9.*/_-]+$ ]] || fail "--node-version '$node_version' is not valid"

target_dir="$(cd "$target" && pwd)"

if [ "$mode" = "monorepo" ]; then
  [ -n "$package_dir" ] || fail "--package-dir is required in monorepo mode"
  package_dir="$(normalize_dir "$package_dir")"
  [ "$package_dir" != "." ] || fail "--package-dir can't be the repo root in monorepo mode (use --mode solo)"
  [ -n "$name" ] || name="$(basename "$package_dir" | tr '[:upper:]_' '[:lower:]-')"
else
  package_dir="$(normalize_dir "${package_dir:-.}")"
  [ "$package_dir" = "." ] || fail "--package-dir only applies to monorepo mode"
fi

is_path "$package_dir" || fail "--package-dir '$package_dir' contains unsupported characters"
[ -f "$target_dir/$package_dir/package.json" ] || fail "no package.json in '$target_dir/$package_dir'"

if [ "$package_dir" = "." ]; then
  package_json="package.json"
else
  package_json="$package_dir/package.json"
fi

# without node, the summary shows <package>
package_name="$(package_json_name "$target_dir/$package_json")"

# solo: "@scope/pkg" → "scope-pkg"
if [ -z "$name" ]; then
  command -v node > /dev/null || fail "node is needed to read the package.json name: install it or pass --name"
  name="$(printf '%s' "$package_name" | tr '[:upper:]' '[:lower:]' | sed -e 's|^@||' -e 's|[^a-z0-9]\{1,\}|-|g' -e 's|^-||' -e 's|-$||')"
  [ -n "$name" ] || name="package"
fi

[[ "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "--name '$name' must match [a-z0-9-] (no leading/trailing dash)"

if [ "$mode" = "monorepo" ]; then
  [ -n "$tag_prefix" ] || tag_prefix="$name-v"
else
  [ -n "$tag_prefix" ] || tag_prefix="v"
fi
# no glob characters: the prefix is used in the tag filter and in ${GITHUB_REF_NAME#prefix}
[[ "$tag_prefix" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "--tag-prefix '$tag_prefix' can only contain letters, digits, '.', '_', '/' and '-'"

github_dir="$target_dir/.github"
workflows_dir="$github_dir/workflows"

if [ "$mode" = "monorepo" ]; then
  workflow_file="release-$name.yml"
else
  workflow_file="release.yml"
fi

# --- existing workflows ---

if [ -e "$workflows_dir/$workflow_file" ] && ! $force; then
  echo "Error: $workflows_dir/$workflow_file already exists. Re-run with --force to overwrite it." >&2
  exit 1
fi

# overlapping tag filters ("v" and "v2-", same prefix) would publish both packages on one tag
if [ -d "$workflows_dir" ]; then
  for f in "$workflows_dir"/*.yml; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" != "$workflow_file" ] || continue
    grep -q '^  push:' "$f" && grep -q '^    tags:' "$f" || continue
    while IFS= read -r other; do
      [ -n "$other" ] || continue
      if [[ "$tag_prefix" == "$other"* ]] || [[ "$other" == "$tag_prefix"* ]]; then
        echo "Error: tag prefix '$tag_prefix' overlaps '$other*' in $f." >&2
        echo "Pick another one with --tag-prefix." >&2
        exit 1
      fi
    done < <(sed -n '/^    tags:/,/^[^ ]/s/^      - "\{0,1\}\([^"*]*\)\*"\{0,1\}$/\1/p' "$f")
  done
fi

# --- blocks ---

export BLOCK_MAIN_CHECK=""
if $main_check; then
  BLOCK_MAIN_CHECK="$(
    printf '      - name: Ensure tag is on main\n'
    printf '        run: |\n'
    printf '          if ! git merge-base --is-ancestor "$GITHUB_SHA" origin/main; then\n'
    printf '            echo "❌ Tag $GITHUB_REF_NAME is not on main. Aborting %s publish to npm workflow."\n' "$name"
    printf '            exit 1\n'
    printf '          fi\n'
    printf '\n'
  )"$'\n'
fi

export BLOCK_CHECK_STEPS=""
if [ ${#checks[@]} -gt 0 ]; then
  BLOCK_CHECK_STEPS="$(
    for check in "${checks[@]}"; do
      printf '      - name: %s\n' "$(yaml_title "Run $check")"
      [ "$package_dir" = "." ] || printf '        working-directory: %s\n' "$package_dir"
      run_block '        ' "$check"
      printf '\n'
    done
  )"$'\n'
fi

# --- write ---

mkdir -p "$workflows_dir"
expand_blocks "$TEMPLATES/workflows/release-package.yml" |
  sed \
    -e "s|__NAME__|$(sed_escape "$name")|g" \
    -e "s|__TAG_PREFIX__|$(sed_escape "$tag_prefix")|g" \
    -e "s|__NODE_VERSION__|$(sed_escape "$node_version")|g" \
    -e "s|__PACKAGE_JSON__|$(sed_escape "$package_json")|g" \
    -e "s|__PACKAGE_DIR__|$(sed_escape "$package_dir")|g" |
  # a solo package is published from the repo root
  sed -e '/^        working-directory: \.$/d' \
  > "$workflows_dir/$workflow_file"
record "$workflows_dir/$workflow_file"

copy_shared "$TEMPLATES/docs/PACKAGES.md" "$github_dir/docs/PACKAGES.md"

# --- summary ---

echo "Generated release workflow for '${package_name:-$name}' ($mode) in $github_dir"
echo
print_files

repo="$(git -C "$target_dir" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##' || true)"

cat <<EOF

Release: git tag ${tag_prefix}<version> && git push origin ${tag_prefix}<version>
         (<version> = "version" in $package_json$($main_check && echo ", tagged commit on main"))

Next steps:
  - npmjs.com: ${package_name:-<package>} → Settings → Trusted publishing → GitHub Actions:
      repository: ${repo:-<owner>/<repo>}, workflow file: $workflow_file
    (the package must exist on npm: publish its first version manually)
EOF
