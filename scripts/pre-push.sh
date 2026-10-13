#!/bin/bash
# The full gate before anything leaves the machine: the whole module is
# verified regardless of what the push contains — a push is rare and cheap
# compared to a broken main. A push whose HEAD is tagged is a release, so that
# one also runs the end-to-end suite and the soak (`verify.sh --release`).
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

# `git describe --exact-match` needs no stdin, which is what keeps this working
# through the Windows→WSL hook bridge (that bridge mangles arguments and output).
if tag=$(git describe --exact-match --tags HEAD 2>/dev/null); then
  echo "pre-push: HEAD 是 tag $tag —— 发布门禁(fmt/check/单测/构建/e2e/soak)..."
  bash "$root/scripts/verify.sh" --release
else
  echo "pre-push: 完整验证(fmt/check/单测/构建;e2e 与 soak 在打 tag 推送时跑)..."
  bash "$root/scripts/verify.sh"
fi

echo "pre-push: ok"
