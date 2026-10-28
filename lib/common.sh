#!/bin/bash
#
# Helpers shared by generate.sh, generate-package.sh and generate-extension.sh. Sourced, each script defines usage()
# and KIT_DIR, and sets target_dir, github_dir and force before writing files.

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

# Writes the names of the secrets used under .github/ to <target>/.env.dist, with their paragraph of the kit's
# .env.dist (a paragraph is written when one of its names is used). An existing file is only appended the missing names.
write_env_dist() {
  local dest="$target_dir/.env.dist" missing

  missing="$(
    USED="$(grep -rhoE 'secrets\.[A-Z0-9_]+' "$github_dir" 2>/dev/null | sed 's/^secrets\.//' | grep -vx GITHUB_TOKEN | sort -u | tr '\n' ' ')" \
    PRESENT="$([ -f "$dest" ] && sed -n 's/^\([A-Za-z0-9_]*\)=.*/\1/p' "$dest" | tr '\n' ' ')" \
    awk '
      function name_of(line) { return line ~ /^[A-Z0-9_]+=/ ? substr(line, 1, index(line, "=") - 1) : "" }
      BEGIN {
        RS = ""; FS = "\n"
        nu = split(ENVIRON["USED"], u, " ")
        for (i = 1; i <= nu; i++) used[u[i]] = 1
        np = split(ENVIRON["PRESENT"], p, " ")
        for (i = 1; i <= np; i++) present[p[i]] = 1
      }
      {
        emit = 0
        for (i = 1; i <= NF; i++) {
          name = name_of($i)
          if (name == "") continue
          known[name] = 1
          if ((name in used) && !(name in present)) emit = 1
        }
        if (!emit) next
        if (out++) print ""
        for (i = 1; i <= NF; i++) {
          name = name_of($i)
          if (name == "" || !(name in present)) print $i
        }
      }
      # secrets the kit does not know (added to a workflow by hand)
      END {
        sep = out
        for (i = 1; i <= nu; i++) {
          if ((u[i] in known) || (u[i] in present)) continue
          if (sep) { print ""; sep = 0 }
          print u[i] "="
        }
      }
    ' "$KIT_DIR/.env.dist"
  )"

  if [ -z "$missing" ]; then
    [ ! -e "$dest" ] || skipped+=("../.env.dist")
    return 0
  fi
  if [ -s "$dest" ]; then
    [ -z "$(tail -c 1 "$dest")" ] || echo >> "$dest"
    echo >> "$dest"
  fi
  printf '%s\n' "$missing" >> "$dest"
  written+=("../.env.dist")
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
