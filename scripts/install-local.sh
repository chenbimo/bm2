#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_dir="$root/_build/native/debug/build/cmd"
target_dir="$HOME/.local/bin"

mkdir -p "$target_dir"
cp "$source_dir/bm2/bm2.exe" "$target_dir/bm2"
cp "$source_dir/bm2d/bm2d.exe" "$target_dir/bm2d"
chmod +x "$target_dir/bm2" "$target_dir/bm2d"
printf 'installed bm2 and bm2d to %s\n' "$target_dir"
