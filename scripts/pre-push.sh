#!/bin/bash
# The gate before anything leaves the machine: the whole module is verified
# regardless of what the push contains — a push is rare and cheap compared to a
# broken main.
#
# The slow suites (e2e, soak) are manual by rule: nothing automatic runs them, a
# tagged release included. They take minutes each, and a gate nobody can afford
# to wait for is a gate people learn to skip. The tail of this script prints the
# manual command for anyone pushing a release.
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
  echo "pre-push: HEAD 是 tag $tag —— 发布门禁(fmt/check/单测/构建)..."
else
  echo "pre-push: 完整验证(fmt/check/单测/构建)..."
fi
bash "$root/scripts/verify.sh"
if [ -n "${tag:-}" ]; then
  echo "pre-push: 耗时的 e2e 与 soak 不在自动流程内,发版前请手动跑: bash scripts/verify.sh --release"
fi

echo "pre-push: ok"
