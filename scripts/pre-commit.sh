#!/bin/bash
# The fast gate on every commit: `moon fmt` (auto-fixed and re-staged) plus the
# strict type/warning check. The slow half — unit tests, native builds, the e2e
# run — belongs to scripts/pre-push.sh.
#
# Runs inside WSL via scripts/hook-dispatch.sh.
set -euo pipefail

# The hook may run from Windows git through WSL as any user; probe the
# well-known toolchain locations instead of trusting $HOME.
if ! command -v moon > /dev/null 2>&1; then
  for candidate in /root/.moon/bin /home/*/.moon/bin "$HOME/.moon/bin"; do
    if [ -x "$candidate/moon" ]; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi

root=$(pwd)
[ -f "$root/moon.mod" ] || {
  echo "pre-commit: no moon.mod here; run from the repository root"
  exit 1
}

# Per-environment build dir: hooks and manual WSL runs share it, and neither
# touches the tree the Windows IDE may be using.
build_dir="$root/_build-wsl"
mkdir -p "$build_dir"

source "$root/scripts/lib/common.sh"

# Only source changes need the compile gate; hook, CI and documentation edits
# do not.
staged=$(git diff --cached --name-only --diff-filter=d)
if [ -z "$staged" ] || ! printf '%s\n' "$staged" | grep -qE '^(src/|moon\.mod$)'; then
  echo "pre-commit: no module sources staged, nothing to check"
  exit 0
fi

# Formatting is fixed automatically rather than reported. The snapshot pair
# tells apart files fmt rewrote (re-stage) from files that also carry the
# committer's own unstaged edits (needs a human decision).
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dirty_snapshot() {
  git diff --name-only --diff-filter=d | while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '%s\t%s\n' "$file" "$(git hash-object -- "$file")"
  done | sort
}

pkgs=$(module_pkgs "$root")

dirty_snapshot > "$tmp/before"
# shellcheck disable=SC2086
moon fmt $pkgs --target-dir "$build_dir" >/dev/null
dirty_snapshot > "$tmp/after"

awk -F'\t' '
  NR == FNR { before[$1] = $2; next }
  {
    after[$1] = 1
    if ($1 in before) {
      if (before[$1] != $2) print "dirty\t" $1
    } else {
      print "new\t" $1
    }
  }
  END { for (file in before) if (!(file in after)) print "reverted\t" file }
' "$tmp/before" "$tmp/after" > "$tmp/reformatted"

needs_attention=0
while IFS=$'\t' read -r kind file; do
  [ -n "$kind" ] || continue
  case "$kind" in
    new)
      echo "pre-commit: moon fmt reformatted and re-staged: $file"
      git add -- "$file"
      ;;
    reverted)
      echo "pre-commit: moon fmt normalized back to the committed content: $file"
      ;;
    dirty)
      echo "pre-commit: moon fmt reformatted $file, which also has your own unstaged edits."
      echo "            git add -- $file   # then commit again"
      needs_attention=1
      ;;
  esac
done < "$tmp/reformatted"
[ "$needs_attention" = 0 ] || exit 1

echo "pre-commit: checking the module ..."
if ! module_check "$root" "$build_dir"; then
  echo "pre-commit: moon check failed; commit aborted."
  echo "            (git commit --no-verify skips this gate)"
  exit 1
fi

# The version invariant: moon.mod and the CLI's VERSION constant agree.
source "$root/scripts/lib/checks.sh"
if ! check_version_sync "$root"; then
  echo "pre-commit: fix the version invariant above before committing."
  exit 1
fi

echo "pre-commit: ok"
