#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/verify.sh
#
# 从 WSL 终端跑:bash scripts/devkit/verify.sh
# 快门禁(本地钩子与 CI 跑的是同一个脚本):推送与 CI 只允许跑到这一档。
#   1. 生成物完整性校验     4. 各 target 测试(DEVKIT_TARGETS)
#   2. 项目声明的校验器     5. 声明的构建(DEVKIT_BUILDS)
#   3. fmt / 严格 check
#
# e2e、soak 等分钟级套件绝不进入本快捷档,只存在于手动命令:
#   --with-e2e 追加慢测试(DEVKIT_E2E),--release 在其上再叠 soak(DEVKIT_SOAK)。
# 插槽没声明就等于没有这一档;任何自动流程与 AI 都不主动跑它们。
set -euo pipefail

WITH_E2E=0
WITH_SOAK=0
for arg in "$@"; do
  case "$arg" in
    --with-e2e) WITH_E2E=1 ;;
    --release) WITH_E2E=1; WITH_SOAK=1 ;;
  esac
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

source "$root/scripts/devkit/lib/common.sh"
source "$root/scripts/devkit/lib/checks.sh"
source "$root/scripts/devkit/lib/manifest.sh"

devkit_integrity_check "$root"
devkit_load_conf "$root"

# 脚手架阶段(还没有 moon.mod)没有可验收的东西,直接放行:让新仓库能正常提交与推送。
if [ ! -f "$root/moon.mod" ]; then
  echo "verify: no moon.mod here yet; nothing to verify"
  exit 0
fi

devkit_ensure_moon

# 项目声明的环境(如锁定输出语言),在跑任何命令前生效。
if [ -n "${DEVKIT_ENV:-}" ]; then
  # shellcheck disable=SC2086
  for kv in $DEVKIT_ENV; do export "$kv"; done
fi

# The build directory is per environment: Windows only edits the sources, while
# every build, test and e2e run happens here in WSL, redirected to _build-wsl.
build_dir="$root/_build-wsl"
mkdir -p "$build_dir"

devkit_run_checks "$root" || exit 1

moon fmt --target-dir "$build_dir"

# A fresh environment (CI, a new machine) starts with an empty mooncakes
# registry index; fetch it before resolving dependencies.
MOON_HOME="${MOON_HOME:-$HOME/.moon}"
if [ ! -d "$MOON_HOME/registry/index" ]; then
  moon update
fi

module_check "$build_dir"

for target in ${DEVKIT_TARGETS:-native}; do
  echo "verify: moon test --target $target"
  if [ -n "${DEVKIT_MODULE:-}" ]; then
    moon test -p "$DEVKIT_MODULE" --target "$target" --target-dir "$build_dir"
  else
    moon test --target "$target" --target-dir "$build_dir"
  fi
done

if [ -n "${DEVKIT_BUILDS:-}" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "verify: moon build $line"
    # shellcheck disable=SC2086
    moon build $line --target-dir "$build_dir"
  done <<< "$DEVKIT_BUILDS"
fi

if [ "$WITH_E2E" = "1" ] && [ -n "${DEVKIT_E2E:-}" ]; then
  echo "verify: 慢测试 -> $DEVKIT_E2E"
  DEVKIT_ROOT="$root" DEVKIT_BUILD_DIR="$build_dir" bash "$root/$DEVKIT_E2E"
fi

if [ "$WITH_SOAK" = "1" ] && [ -n "${DEVKIT_SOAK:-}" ]; then
  echo "verify: soak -> $DEVKIT_SOAK"
  DEVKIT_ROOT="$root" DEVKIT_BUILD_DIR="$build_dir" bash "$root/$DEVKIT_SOAK"
fi

if [ "$WITH_E2E" = "0" ]; then
  echo "verify: fmt/check/测试/构建 ok(--with-e2e 与 --release 是分钟级手动档)"
else
  echo "verify: ok"
fi
