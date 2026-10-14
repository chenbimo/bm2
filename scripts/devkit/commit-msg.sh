#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/commit-msg.sh
#
# 强制仓库提交信息约定(见 AGENTS.md 与 moonbit/scripts/README.md):
#
#   [项目名](类型) 提交内容
#
# Merge 与 Revert 豁免——首行由 git 生成。
# 项目名从 scripts/devkit.conf 的 DEVKIT_NAME 读,骨架不写死任何项目。
# 在 WSL 内由 scripts/devkit/hook-dispatch.sh 调起;消息文件是仓库的
# .git/COMMIT_EDITMSG,由仓库根推导,不跨 Windows/WSL 边界传参。
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

source "$root/scripts/devkit/lib/common.sh"
devkit_load_conf "$root"

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

if ! printf '%s' "$first" | grep -qE "^\[$DEVKIT_NAME\]\((feat|fix|docs|refactor|test|chore)\) [^ ].*$"; then
  cat <<EOF
commit-msg: 提交说明不符合仓库约定(见 AGENTS.md 与 moonbit/scripts/README.md)。

  实际首行: $first
  要求格式: [项目名](类型) 提交内容
    项目名: $DEVKIT_NAME
    类型:   feat | fix | docs | refactor | test | chore

(确实需要跳过: git commit --no-verify)
EOF
  exit 1
fi

echo "commit-msg: ok"
