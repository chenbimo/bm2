#!/bin/bash
# Enforce the repository commit-message convention (see AGENTS.md):
#
#   [项目名](类型) 提交内容
#
# Merge and revert commits are exempt — git generates their first line.
# Runs inside WSL via scripts/hook-dispatch.sh. The message file is the repo's
# .git/COMMIT_EDITMSG (git always prepares it there for -m/-F; MERGE_MSG for
# merges), derived from the repository root rather than passed across the
# Windows/WSL boundary.
set -euo pipefail

msgfile="${1:-.git/COMMIT_EDITMSG}"
if [ ! -f "$msgfile" ]; then
  echo "commit-msg: no commit message file received"
  exit 1
fi

first=$(head -n 1 "$msgfile" | tr -d '\r')

case "$first" in
  "Merge "*|"Revert "*)
    echo "commit-msg: merge/revert commit, format check skipped"
    exit 0
    ;;
esac

# 单仓库单项目:项目名只有 bm2。
if ! printf '%s' "$first" | grep -qE "^\[bm2\]\((feat|fix|docs|refactor|test|chore)\) [^ ].*$"; then
  cat <<EOF
commit-msg: 提交说明不符合仓库约定(见根目录 AGENTS.md)。

  实际首行: $first
  要求格式: [项目名](类型) 提交内容
    项目名: bm2
    类型:   feat | fix | docs | refactor | test | chore
  示例:    [bm2](feat) 新增 reload 命令

(确实需要跳过: git commit --no-verify)
EOF
  exit 1
fi

echo "commit-msg: ok"
