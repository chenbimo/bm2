#!/bin/bash
# Run from the Remote-WSL terminal: bash scripts/verify.sh
set -euo pipefail

export PATH="$HOME/.moon/bin:$PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# mktemp does not create parent directories, and a fresh checkout has no
# _build yet (moon build runs only later in this script).
mkdir -p "$root/_build"
bin_dir=$(mktemp -d "$root/_build/bm2-e2e-bin.XXXXXX")
trap 'rm -rf "$bin_dir"' EXIT

cd "$root"

# The CLI's VERSION constant must match moon.mod so `bm2 version` and
# mooncakes releases never drift apart.
MV=$(sed -nE 's/^version = "([^"]+)"/\1/p' "$root/moon.mod")
if ! grep -q "const VERSION : String = \"$MV\"" "$root/src/cmd/bm2/main.mbt"; then
  echo "VERSION mismatch: moon.mod says $MV but src/cmd/bm2/main.mbt differs"
  exit 1
fi

moon fmt

# A fresh environment (CI, a new machine) starts with an empty mooncakes
# registry index; fetch it before resolving dependencies. Locally the
# cached index usually exists and the network round-trip is skipped.
if [ ! -f "$HOME/.moon/registry/index/user/bobzhang/toml.index" ]; then
  moon update
fi

moon check --target native --deny-warn
moon test --target native
moon build --target native

cp _build/native/debug/build/cmd/bm2/bm2.exe "$bin_dir/bm2"
cp _build/native/debug/build/cmd/bm2d/bm2d.exe "$bin_dir/bm2d"
chmod +x "$bin_dir/bm2" "$bin_dir/bm2d"

BM2_BIN_DIR="$bin_dir" bash scripts/e2e/run.sh
