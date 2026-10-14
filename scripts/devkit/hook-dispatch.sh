#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/hook-dispatch.sh
#
# Git hook dispatcher: run one hook stage inside the environment that actually
# has the toolchain.
#
# The checks need the MoonBit toolchain, which lives in WSL; git, however, is
# usually driven from Windows. The hook crosses that boundary instead of
# demanding a toolchain on both sides.
#
# Activated via: git config core.hooksPath .githooks
set -u

stage=${1:?usage: hook-dispatch.sh <stage> [args...]}
shift || true

root=$(git rev-parse --show-toplevel)

case "$(uname -s)" in
  Linux*)
    cd "$root"
    exec bash "scripts/devkit/$stage.sh" "$@"
    ;;
  *)
    if ! command -v wsl.exe >/dev/null 2>&1; then
      echo "git-hook: wsl.exe not found, but the checks need the WSL toolchain."
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
    # 无参数设计:commit-msg 需要的消息文件在 WSL 侧路径确定
    # (<wsl_root>/.git/COMMIT_EDITMSG),由 commit-msg.sh 自行推导,
    # 不跨桥传参——参数桥在部分环境下会丢参。
    exec wsl.exe -d Debian -- bash -lc "cd '$wsl_root' && bash scripts/devkit/$stage.sh"
    ;;
esac
