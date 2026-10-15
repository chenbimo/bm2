#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/pre-push.sh
#
# 推送只触发快门禁:format(moon fmt)、lint(moon check --deny-warn)、测试,以及
# 秒级增量的构建 —— 由同一条 verify.sh 定义。e2e、soak 等任何分钟级套件按规矩
# 只手动跑(verify.sh --with-e2e / --release):任何自动流程都不跑它们,打 tag 的
# 推送也不例外。尾部提示是给发版的人看的。
#
# 在 WSL 内由 scripts/devkit/hook-dispatch.sh 调起。
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

# `git describe --exact-match` needs no stdin, which is what keeps this working
# through the Windows→WSL hook bridge (that bridge mangles arguments and output).
if tag=$(git describe --exact-match --tags HEAD 2>/dev/null); then
  echo "pre-push: HEAD 是 tag $tag —— 快门禁(fmt/lint/test/构建)..."
else
  echo "pre-push: 快门禁(fmt/lint/test/构建)..."
fi
# 无需在这里探测工具链或缺 moon.mod 的脚手架:verify.sh 两者都处理了。
bash "$root/scripts/devkit/verify.sh"
if [ -n "${tag:-}" ]; then
  echo "pre-push: 耗时的慢测试不在自动流程内,发版前请手动跑: bash scripts/devkit/verify.sh --release"
fi

echo "pre-push: ok"
