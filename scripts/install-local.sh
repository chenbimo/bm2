#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_dir="$root/_build/native/debug/build/cmd"
target_dir="$HOME/.local/bin"

mkdir -p "$target_dir"
for command in bm2 bm2d; do
  cp "$source_dir/$command/$command.exe" "$target_dir/$command.new"
  chmod +x "$target_dir/$command.new"
  mv -f "$target_dir/$command.new" "$target_dir/$command"
done
printf 'installed bm2 and bm2d to %s\n' "$target_dir"
