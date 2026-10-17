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

    # 不需要 MoonBit 工具链的阶段直接在 Git Bash 里跑,省掉一次 WSL 启动(实测数秒):
    # - commit-msg 只做提交信息格式正则,纯 grep;
    # - pre-commit 无模块源暂存时只是提前退出(pre-commit.sh 自己判),生成物完整性
    #   校验(sha256sum -c)在 Git Bash 也能跑。一旦命中 DEVKIT_SRC/moon.mod,仍然进 WSL。
    if [ "$stage" = "commit-msg" ] || [ "$stage" = "pre-commit" ]; then
      need_local=0
      if [ "$stage" = "commit-msg" ]; then
        need_local=1
      else
        # 读取项目声明:未声明 DEVKIT_SRC 或无源码暂存时,pre-commit.sh 本就地提前返回
        devkit_src=""
        [ -f "$root/scripts/devkit.conf" ] &&
          devkit_src=$(sed -nE 's/^DEVKIT_SRC="?([^"#]*)"?/\1/p' "$root/scripts/devkit.conf" | head -1)
        if [ -z "$devkit_src" ] ||
          ! (cd "$root" && git diff --cached --name-only --diff-filter=d | grep -qE "^(${devkit_src}|moon\.mod$)"); then
          need_local=1
        fi
      fi
      if [ "$need_local" = "1" ]; then
        cd "$root"
        exec bash "scripts/devkit/$stage.sh" "$@"
      fi
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
