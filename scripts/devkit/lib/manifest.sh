#!/bin/bash
# 生成物 · 禁改。源:moonbit/scripts/static/scripts/devkit/lib/manifest.sh
#
# 生成物的漂移防线。scripts/devkit/**、.githooks/**、.github/workflows/verify.yml
# 都由 moonbit/scripts 生成,手改就是 bug:这里按 .manifest 重算每个文件的哈希,
# 不符即拒绝提交。
#
# 戳记由 moonbit/scripts/devkit.sh sync 写入;校验本身不需要源树,所以 CI 也能跑。

devkit_integrity_check() {
  local root="$1" manifest="$1/scripts/devkit/.manifest" out
  if [ ! -f "$manifest" ]; then
    echo "devkit: $manifest missing; run: bash moonbit/scripts/devkit.sh sync" >&2
    return 1
  fi
  # LC_ALL=C keeps the verdict messages locale-independent; --quiet prints only
  # the failures.
  if ! out=$(cd "$root" && LC_ALL=C sha256sum -c --quiet scripts/devkit/.manifest 2>&1); then
    echo "devkit: generated files were edited by hand (they are built by sync):" >&2
    printf '%s\n' "$out" >&2
    echo "devkit: run: bash moonbit/scripts/devkit.sh sync" >&2
    return 1
  fi
}
