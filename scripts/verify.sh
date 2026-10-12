#!/bin/bash
# Run from the Remote-WSL terminal: bash scripts/verify.sh
# Default gate: fmt / check / unit tests / native build.
# Pass --with-e2e to also run the end-to-end suite — that full gate belongs
# to the release flow (run it manually before publishing), not to everyday
# commits.
set -euo pipefail

WITH_E2E=0
for arg in "$@"; do
  [ "$arg" = "--with-e2e" ] && WITH_E2E=1
done

# The push hook may arrive from Windows git through WSL as any user, so
# $HOME cannot be trusted to hold the toolchain: probe the well-known
# install locations instead.
if ! command -v moon > /dev/null 2>&1; then
  for candidate in /root/.moon/bin /home/*/.moon/bin "$HOME/.moon/bin"; do
    if [ -x "$candidate/moon" ]; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi
if ! command -v moon > /dev/null 2>&1; then
  echo "verify.sh: moon not found (looked in /root/.moon/bin, /home/*/.moon/bin, \$HOME/.moon/bin)" >&2
  exit 1
fi
export PATH="$(command -v moon | xargs dirname):$PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The build directory is per environment: Windows only edits the sources (its
# IDE runs its own toolchain against the default _build), while every build,
# test and e2e run happens here in WSL, redirected to _build-wsl. Keeping the
# two trees apart stops the toolchains from corrupting each other's caches.
build_dir="$root/_build-wsl"
mkdir -p "$build_dir"

cd "$root"

# shellcheck source=scripts/lib/common.sh
source "$root/scripts/lib/common.sh"
# shellcheck source=scripts/lib/checks.sh
source "$root/scripts/lib/checks.sh"
check_version_sync "$root" || exit 1

# Single-module repository: every package under src/ belongs to bm2, including
# the vendored libraries under src/vendor/.
pkgs=$(module_pkgs "$root")

moon fmt $pkgs --target-dir "$build_dir"

# A fresh environment (CI, a new machine) starts with an empty mooncakes
# registry index; fetch it before resolving dependencies. Locally the
# cached index usually exists and the network round-trip is skipped.
MOON_HOME="${MOON_HOME:-$HOME/.moon}"
if [ ! -f "$MOON_HOME/registry/index/user/moonbit-community/toml.index" ]; then
  moon update
fi

# The explicit warn list adds the deprecation warnings the IDE shows by
# default (implicit trait-method promotion); the pre-commit hook and CI both
# gate on them, so they cannot creep back in unnoticed.
moon check $pkgs --target-dir "$build_dir" --target native --deny-warn --warn-list +implicit_impl_as_method
moon test -p chensuiyi/bm2 --target-dir "$build_dir" --target native
moon build "$root/src/cmd/bm2" "$root/src/cmd/bm2d" --target-dir "$build_dir" --target native

if [ "$WITH_E2E" = "1" ]; then
  # mktemp does not create parent directories; the build above made the tree.
  bin_dir=$(mktemp -d "$build_dir/bm2-e2e-bin.XXXXXX")
  trap 'rm -rf "$bin_dir"' EXIT
  cp "$build_dir/native/debug/build/chensuiyi/bm2/cmd/bm2/bm2.exe" "$bin_dir/bm2"
  cp "$build_dir/native/debug/build/chensuiyi/bm2/cmd/bm2d/bm2d.exe" "$bin_dir/bm2d"
  chmod +x "$bin_dir/bm2" "$bin_dir/bm2d"
  BM2_BIN_DIR="$bin_dir" bash scripts/e2e/run.sh
else
  echo "verify: fmt/check/unit/build ok (e2e skipped; release runs it via --with-e2e)"
fi
