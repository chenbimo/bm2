#!/bin/bash
# The fast gate that runs on every commit (see .githooks/pre-commit).
#
# Scope: formatting, the version invariant, and the type/warning check. The
# slow half of the suite — unit tests, the native build and the end-to-end
# acceptance run — belongs to the pre-push hook, which calls verify.sh.
#
# Runs inside WSL/Linux; scripts/git-hook.sh is what gets it there.
set -euo pipefail

export PATH="$HOME/.moon/bin:$PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# Same per-environment build dir as verify.sh, so the hook and the full entry
# share one cache and neither touches the tree the Windows IDE may be using.
build_dir="$root/_build-wsl"
mkdir -p "$build_dir"

# shellcheck source=scripts/lib/checks.sh
source "$root/scripts/lib/checks.sh"

# Formatting is fixed automatically rather than reported: it is never worth
# blocking a commit over whitespace. To re-stage only what moon fmt itself
# rewrote, the hook snapshots every unstaged file with its content hash before
# and after the run.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dirty_snapshot() {
  git diff --name-only | while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '%s\t%s\n' "$file" "$(git hash-object -- "$file")"
  done | sort
}

dirty_snapshot > "$tmp/before"
moon fmt --target-dir "$build_dir" >/dev/null
dirty_snapshot > "$tmp/after"

# new      -> clean before, different after: fmt is the only author, re-stage it.
# reverted -> its formatting-only edit is gone again: nothing left to stage.
# dirty    -> the file also carries unstaged edits, so the formatting cannot be
#             staged without staging those too; that needs a human decision.
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

if ! check_version_sync "$root"; then
  echo "pre-commit: fix the version invariant above before committing."
  exit 1
fi

# The same checker verify.sh and CI run, plus the deprecation warnings the IDE
# reports by default: a warning is a defect here, not a suggestion.
if ! moon check --target-dir "$build_dir" --target native --deny-warn --warn-list +implicit_impl_as_method; then
  echo "pre-commit: moon check found problems; commit aborted."
  echo "            (git commit --no-verify skips this gate)"
  exit 1
fi

echo "pre-commit: ok"
