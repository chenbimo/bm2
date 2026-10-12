#!/bin/bash
# The full gate before anything leaves the machine: the whole module is
# verified regardless of what the push contains — a push is rare and cheap
# compared to a broken main. The end-to-end suite stays manual (run
# `bash scripts/verify.sh --with-e2e` before publishing).
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
  echo "pre-push: no moon.mod here; run from the repository root"
  exit 1
}

echo "pre-push: 完整验证(fmt/check/单测/构建;e2e 发布前手动跑)..."
bash "$root/scripts/verify.sh"

echo "pre-push: ok"
