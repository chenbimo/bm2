#!/bin/bash
# Run from the Remote-WSL terminal: bash scripts/verify.sh
set -euo pipefail

export PATH="$HOME/.moon/bin:$PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin_dir=$(mktemp -d "$root/_build/bm2-e2e-bin.XXXXXX")
trap 'rm -rf "$bin_dir"' EXIT

cd "$root"
moon fmt
moon check --target native --deny-warn
moon test --target native
moon build --target native

cp _build/native/debug/build/cmd/bm2/bm2.exe "$bin_dir/bm2"
cp _build/native/debug/build/cmd/bm2d/bm2d.exe "$bin_dir/bm2d"
chmod +x "$bin_dir/bm2" "$bin_dir/bm2d"

BM2_BIN_DIR="$bin_dir" bash scripts/e2e/run.sh
