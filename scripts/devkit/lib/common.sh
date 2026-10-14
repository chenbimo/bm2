#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/lib/common.sh
#
# 骨架的公共部分:定位 MoonBit 工具链、加载项目声明、提供严格 check 门。
# 单模块仓库:`moon fmt` / `moon check` 不带包过滤,仓库根即模块根。

# The MoonBit toolchain lives in WSL (or on the CI runner) but never on Windows,
# and a hook may arrive through the WSL bridge as any user, so $HOME cannot be
# trusted: probe the well-known install locations instead.
devkit_ensure_moon() {
  if command -v moon > /dev/null 2>&1; then
    return 0
  fi
  local candidate
  for candidate in /root/.moon/bin /home/*/.moon/bin "$HOME/.moon/bin"; do
    if [ -x "$candidate/moon" ]; then
      export PATH="$candidate:$PATH"
      return 0
    fi
  done
  echo "devkit: moon not found (looked in /root/.moon/bin, /home/*/.moon/bin, \$HOME/.moon/bin)" >&2
  return 1
}

# Load the project's business declaration. Every project has exactly one, at
# scripts/devkit.conf; the skeleton reads it and never invents values of its own.
devkit_load_conf() {
  local root="$1" conf="$root/scripts/devkit.conf"
  if [ ! -f "$conf" ]; then
    echo "devkit: missing $conf (the project's business declaration; see moonbit/scripts/templates/devkit.conf)" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$conf"
  : "${DEVKIT_NAME:?DEVKIT_NAME missing in scripts/devkit.conf}"
  DEVKIT_MODULE=${DEVKIT_MODULE:-}
  DEVKIT_SRC=${DEVKIT_SRC:-src/}
  DEVKIT_TARGETS=${DEVKIT_TARGETS:-native}
  DEVKIT_BUILDS=${DEVKIT_BUILDS:-}
  DEVKIT_CHECKS=${DEVKIT_CHECKS:-}
  DEVKIT_VERSION_FILE=${DEVKIT_VERSION_FILE:-}
  DEVKIT_ENV=${DEVKIT_ENV:-}
  DEVKIT_E2E=${DEVKIT_E2E:-}
  DEVKIT_SOAK=${DEVKIT_SOAK:-}
}

# The strict type/warning gate that must pass before a commit. The explicit warn
# list adds the deprecation warnings the IDE shows by default, so they cannot
# creep back in unnoticed.
module_check() {
  local build_dir="$1"
  moon check --target-dir "$build_dir" --target native --deny-warn --warn-list +implicit_impl_as_method
}
