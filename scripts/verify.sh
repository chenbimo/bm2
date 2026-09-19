#!/bin/bash
# Run from the Remote-WSL terminal: bash scripts/verify.sh
set -euo pipefail

export PATH="$HOME/.moon/bin:$PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The build directory is per environment: Windows only edits the sources (its
# IDE runs a newer toolchain), while every build, test and e2e run happens here
# in WSL. Keeping WSL's outputs in a separate tree stops the two toolchains
# from corrupting each other's caches.
build_dir="$root/_build-wsl"
# mktemp does not create parent directories, and a fresh checkout has no build
# dir yet (moon build runs only later in this script).
mkdir -p "$build_dir"
bin_dir=$(mktemp -d "$build_dir/bm2-e2e-bin.XXXXXX")
trap 'rm -rf "$bin_dir"' EXIT

cd "$root"

# shellcheck source=scripts/lib/checks.sh
source "$root/scripts/lib/checks.sh"
check_version_sync "$root" || exit 1

moon fmt --target-dir "$build_dir"

# A fresh environment (CI, a new machine) starts with an empty mooncakes
# registry index; fetch it before resolving dependencies. Locally the
# cached index usually exists and the network round-trip is skipped.
MOON_HOME="${MOON_HOME:-$HOME/.moon}"
if [ ! -f "$MOON_HOME/registry/index/user/bobzhang/toml.index" ]; then
  moon update
fi

# The explicit warn list adds the deprecation warnings the IDE shows by
# default (implicit trait-method promotion); the pre-commit hook and CI both
# gate on them, so they cannot creep back in unnoticed.
moon check --target-dir "$build_dir" --target native --deny-warn --warn-list +implicit_impl_as_method
moon test --target-dir "$build_dir" --target native
moon build --target-dir "$build_dir" --target native

cp "$build_dir/native/debug/build/cmd/bm2/bm2.exe" "$bin_dir/bm2"
cp "$build_dir/native/debug/build/cmd/bm2d/bm2d.exe" "$bin_dir/bm2d"
chmod +x "$bin_dir/bm2" "$bin_dir/bm2d"

BM2_BIN_DIR="$bin_dir" bash scripts/e2e/run.sh
