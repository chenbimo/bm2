#!/bin/bash
# Git hook dispatcher: run one hook stage inside the environment that actually
# has the toolchain.
#
# bm2 is Linux-only and its checks need the MoonBit toolchain and bun, which
# live in WSL. Git, however, is usually driven from Windows (VS Code, Git Bash)
# because the working tree sits on a Windows drive. So the hook crosses that
# boundary instead of demanding a toolchain on both sides.
#
# Sets up via: git config core.hooksPath .githooks
set -u

stage=${1:?usage: git-hook.sh <stage>}

case "$stage" in
  pre-commit) target="scripts/pre-commit.sh" ;;
  pre-push) target="scripts/verify.sh" ;;
  *)
    echo "git-hook: unknown stage '$stage'"
    exit 1
    ;;
esac

root=$(git rev-parse --show-toplevel)

case "$(uname -s)" in
  Linux*)
    cd "$root"
    exec bash "$target"
    ;;
  *)
    # Running on Windows: hand the work to WSL. wsl.exe converts the Windows
    # path in --cd, so the script lands in the same tree.
    if ! command -v wsl.exe >/dev/null 2>&1; then
      echo "git-hook: wsl.exe not found, but bm2's checks need the WSL toolchain."
      echo "          Commit from WSL, or skip this hook with --no-verify."
      exit 1
    fi
    # Keep MSYS/Git Bash from rewriting the Unix paths we pass through.
    MSYS2_ARG_CONV_EXCL='*'
    export MSYS2_ARG_CONV_EXCL
    wsl_root=$(wsl.exe -d Debian -- wslpath -u "$root" 2>/dev/null | tr -d '\r')
    if [ -z "$wsl_root" ]; then
      echo "git-hook: cannot translate '$root' to a WSL path."
      exit 1
    fi
    exec wsl.exe -d Debian -- bash -lc "cd '$wsl_root' && bash $target"
    ;;
esac
