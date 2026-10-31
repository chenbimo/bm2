#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/lib/checks.sh
#
# 可组合的发布不变量。每个校验器收下仓库根,违反时返回非零。
# 项目通过 scripts/devkit.conf 的 DEVKIT_CHECKS 选择跑哪些,
# 于是项目的特殊规则永远不碰共享骨架——这是「声明」那一层的落点。

# 声明的版本常量必须与 moon.mod 一致,CLI 报的版本与发布列表才不会飘。
# 只有设了 DEVKIT_VERSION_FILE 的项目才启用。
check_version_sync() {
  local root="$1" mv
  [ -n "${DEVKIT_VERSION_FILE:-}" ] || return 0
  mv=$(sed -nE 's/^version = "([^"]+)"/\1/p' "$root/moon.mod")
  if ! grep -q "const VERSION : String = \"$mv\"" "$root/$DEVKIT_VERSION_FILE"; then
    echo "VERSION mismatch: moon.mod says $mv but $DEVKIT_VERSION_FILE differs"
    return 1
  fi
}

# 发布到 mooncakes 要求 moon.mod 完整,且 readme 指向真实文件。
check_package_metadata() {
  local root="$1" key missing="" readme
  for key in version license description repository readme; do
    if ! grep -qE "^${key} = " "$root/moon.mod"; then
      missing="$missing $key"
    fi
  done
  if [ -n "$missing" ]; then
    echo "moon.mod 缺少必备字段:$missing"
    return 1
  fi
  readme=$(sed -nE 's/^readme = "([^"]+)"/\1/p' "$root/moon.mod")
  if [ ! -f "$root/$readme" ]; then
    echo "moon.mod 的 readme 指向了不存在的文件:$readme"
    return 1
  fi
}

# 本地工具链必须与唯一源钉住的版本一致。
#
# 两边跑不同编译器时,连依赖能不能解析都可能不同:async 0.22.6 起依赖
# moonbitlang/core/async,旧 core 里没有这个包,于是本地(新 core)全绿、CI(旧 core)
# 在计算构建计划时就红了。所以不一致要在这里停下,而不是等 CI 报错。
#
# pin 的权威值是生成出来的 workflow 里的 MOONBIT_INSTALL_VERSION(由
# moonbit/scripts/devkit.conf 渲染),这里读它,不另立一份清单。
check_toolchain_pin() {
  local root="$1" pin local_version
  pin=$(sed -nE 's/^ *MOONBIT_INSTALL_VERSION: *//p' \
    "$root/.github/workflows/verify.yml" 2>/dev/null | head -1)
  [ -n "$pin" ] || return 0
  local_version=$(moonc -v 2>/dev/null | sed -nE 's/^v([^ ]+).*/\1/p')
  [ -n "$local_version" ] || return 0
  if [ "$local_version" != "$pin" ]; then
    echo "toolchain pin mismatch: CI pins $pin, local moonc is $local_version" >&2
    echo "  本地与 CI 必须是同一个编译器,否则依赖解析结果都可能不同。" >&2
    echo "  升级工具链后,把新版本写进 moonbit/scripts/devkit.conf 的 MOONC_VERSION 并 sync。" >&2
    return 1
  fi
}

# 按 DEVKIT_CHECKS 依次执行;未知名字直接报错,防止拼错后静默跳过。
devkit_run_checks() {
  local root="$1" name
  for name in ${DEVKIT_CHECKS:-}; do
    # 清单里写裸名字(如 package_metadata),实现按 check_<名字> 约定命名。
    fn="check_$name"
    if ! declare -F "$fn" > /dev/null; then
      echo "devkit: unknown checker '$name' in DEVKIT_CHECKS (expected function $fn)" >&2
      return 1
    fi
    if ! "$fn" "$root"; then
      return 1
    fi
  done
}
