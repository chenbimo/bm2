#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/pre-commit.sh
#
# 每次提交的快门:生成物完整性 + `moon fmt`(自动修复并重暂存)+ 严格 check +
# 项目声明的校验器。慢的一档(测试、构建、慢测试)属于 pre-push。
#
# 在 WSL 内由 scripts/devkit/hook-dispatch.sh 调起。
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

source "$root/scripts/devkit/lib/common.sh"
source "$root/scripts/devkit/lib/checks.sh"
source "$root/scripts/devkit/lib/manifest.sh"

devkit_integrity_check "$root"

devkit_load_conf "$root"

# 只有源码改动才需要编译门;钩子、CI、文档的改动不需要。
staged=$(git diff --cached --name-only --diff-filter=d)
if [ -z "$staged" ] || ! printf '%s\n' "$staged" | grep -qE "^(${DEVKIT_SRC}|moon\.mod$)"; then
  echo "pre-commit: no module sources staged, nothing to check"
  exit 0
fi

devkit_ensure_moon

# Per-environment build dir: hooks and manual WSL runs share it, and neither
# touches the tree the Windows IDE may be using.
build_dir="$root/_build-wsl"
mkdir -p "$build_dir"

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

dirty_snapshot > "$tmp/before"
moon fmt --target-dir "$build_dir" >/dev/null
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
if ! module_check "$build_dir"; then
  echo "pre-commit: moon check failed; commit aborted."
  echo "            (git commit --no-verify skips this gate)"
  exit 1
fi

if ! devkit_run_checks "$root"; then
  echo "pre-commit: 固定校验未通过,提交中止。"
  exit 1
fi

echo "pre-commit: ok"
