#!/bin/bash
#
# Helpers shared by generate.sh, generate-package.sh and generate-extension.sh. Sourced, each script defines usage(),
# and sets github_dir and force before writing files.

written=()
skipped=()
outdated=()
removed=()

fail() {
  echo "Error: $1" >&2
  echo >&2
  usage >&2
  exit 1
}

need_value() {
  [ $# -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
}

# Checks --target and sets target_dir to its absolute path.
validate_target() {
  [ -n "$target" ] || fail "--target is required"
  [ -d "$target" ] || fail "--target '$target' is not a directory"
  target_dir="$(cd "$target" && pwd)"
}

# Checks --mode is solo or monorepo.
validate_mode() {
  [ -n "$mode" ] || fail "--mode is required (solo or monorepo)"
  [ "$mode" = "solo" ] || [ "$mode" = "monorepo" ] || fail "--mode must be solo or monorepo"
}

# Exits when one of the given files exists, unless --force.
refuse_existing() {
  local f
  local existing=()

  $force && return 0
  for f in "$@"; do
    [ -e "$f" ] && existing+=("$f")
  done
  [ ${#existing[@]} -gt 0 ] || return 0

  echo "Error: these files already exist:" >&2
  printf '  %s\n' "${existing[@]}" >&2
  echo "Re-run with --force to overwrite them." >&2
  exit 1
}

is_path() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]]
}

# strips "./" and trailing "/", "." stays "."
normalize_dir() {
  local dir="${1#./}"
  dir="${dir%/}"
  printf '%s' "${dir:-.}"
}

# Escapes a value for the replacement side of a sed s||| command.
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# Prints a template, each line that is only __NAME__ (possibly indented) replaced by $BLOCK_NAME
# (an exported, possibly multi-line block, each line indented like the placeholder), or dropped
# when it's empty. Inline __TOKEN__s are left to the caller.
expand_blocks() {
  awk '
    /^ *__[A-Z_]+__$/ {
      match($0, /^ */)
      indent = substr($0, 1, RLENGTH)
      name = substr($0, RLENGTH + 3, length($0) - RLENGTH - 4)
      block = ENVIRON["BLOCK_" name]
      if (block == "") next
      n = split(block, lines, "\n")
      for (i = 1; i <= n; i++) print (lines[i] == "" ? "" : indent lines[i])
      next
    }
    { print }
  ' "$1"
}

# Prints a template with its block lines expanded (expand_blocks) and each inline __TOKEN__
# replaced, in argument order: fill_template <template> TOKEN=value...
fill_template() {
  local template="$1" pair
  local sed_args=()

  shift
  for pair in "$@"; do
    sed_args+=(-e "s|__${pair%%=*}__|$(sed_escape "${pair#*=}")|g")
  done
  expand_blocks "$template" | sed "${sed_args[@]}"
}

# Prints a "run: |" key, never a plain scalar a command could break (": ", "#", "true"…):
# run_block <indent> <cmd>
run_block() {
  printf '%srun: |\n' "$1"
  printf '%s\n' "$2" | sed "s|^|$1  |"
}

# Prints the first line of a text as a double-quoted YAML string.
yaml_title() {
  printf '"%s"' "$(printf '%s\n' "$1" | head -n 1 | sed -e 's/[\\"]/\\&/g')"
}

capitalize() {
  printf '%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')${1:1}"
}

# Prints a package.json's "name", empty without node (no regex guess: nested "name"s exist).
package_json_name() {
  command -v node > /dev/null || return 0
  node -p 'require(process.argv[1]).name || ""' "$1" 2>/dev/null || true
}

record() {
  written+=("${1#"$github_dir"/}")
}

# Writes a command's output to a generated file and records it: write_file <dest> <cmd> [args...]
# (not fed from a pipe: record would run in a subshell)
write_file() {
  local dest="$1"

  shift
  mkdir -p "$(dirname "$dest")"
  "$@" > "$dest"
  record "$dest"
}

# Shared files: kept as-is when present, unless --force.
copy_shared() {
  local src="$1" dest="$2"

  if [ -e "$dest" ] && ! $force; then
    if cmp -s "$src" "$dest"; then
      skipped+=("${dest#"$github_dir"/}")
    else
      outdated+=("${dest#"$github_dir"/}")
    fi
    return
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  case "$dest" in *.sh) chmod +x "$dest" ;; esac
  record "$dest"
}

print_files() {
  if [ ${#written[@]} -gt 0 ]; then
    echo "Written:"
    printf '  %s\n' "${written[@]}"
  fi
  if [ ${#skipped[@]} -gt 0 ]; then
    echo "Kept existing (identical to the kit):"
    printf '  %s\n' "${skipped[@]}"
  fi
  if [ ${#outdated[@]} -gt 0 ]; then
    echo "Kept existing, DIFFERENT from the kit (re-run with --force to update them):"
    printf '  %s\n' "${outdated[@]}"
  fi
  if [ ${#removed[@]} -gt 0 ]; then
    echo "Removed:"
    printf '  %s\n' "${removed[@]}"
  fi
}
