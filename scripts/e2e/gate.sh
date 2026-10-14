#!/bin/bash
# bm2 专属慢测试门:verify.sh 的 e2e 插槽(项目自己的业务,不进共享骨架)。
#
# verify.sh 已经构建过 bm2 / bm2d,这里把产物拷到临时目录再交给 scripts/e2e/run.sh。
# 产物一律按名字解析并要求它新于本包源码:构建产物路径随 moon 版本变动
# (native/debug/build/<module>/<pkg>/x.exe 变成 build/<pkg>/x.exe),硬编码会在旧
# 文件仍在原处时静默跑旧二进制,e2e 照样绿灯。
#
# 由 verify.sh 调起,环境里有 DEVKIT_ROOT 与 DEVKIT_BUILD_DIR。
set -euo pipefail

root=${DEVKIT_ROOT:?DEVKIT_ROOT not set}
build_dir=${DEVKIT_BUILD_DIR:-$root/_build-wsl}

bin_dir=$(mktemp -d "$build_dir/bm2-e2e-bin.XXXXXX")
trap 'rm -rf "$bin_dir"' EXIT

for name in bm2 bm2d; do
  exe=$(find "$build_dir" -name "$name.exe" -printf '%T@ %p\n' |
    sort -rn | head -1 | cut -d' ' -f2-)
  if [ -z "$exe" ]; then
    echo "e2e-gate: no built $name.exe under $build_dir" >&2
    exit 1
  fi
  newest=$(find "$root/src/cmd/$name" -name '*.mbt' -printf '%T@ %p\n' |
    sort -rn | head -1)
  if [ "$(stat -c %Y "$exe")" -lt "${newest%%.*}" ]; then
    echo "e2e-gate: $name.exe is older than its own package sources ($exe): the build did not refresh it" >&2
    exit 1
  fi
  cp "$exe" "$bin_dir/$name"
done
chmod +x "$bin_dir/bm2" "$bin_dir/bm2d"

BM2_BIN_DIR="$bin_dir" bash "$root/scripts/e2e/run.sh"
