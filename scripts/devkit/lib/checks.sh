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
