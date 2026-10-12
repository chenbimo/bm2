#!/bin/bash
# Shared helpers for the verification gate and the git hooks.
#
# Single-module repository: bm2 is the only module, so the old workspace
# member registry is gone. What remains is the package list that every gate
# feeds to `moon fmt` / `moon check`.

# Every package of the module, including the vendored libraries under
# src/vendor/. Printed space-separated on a single line.
module_pkgs() {
  local root="$1"
  printf '%s' "$root/src $root/src/config $root/src/core $root/src/ipc $root/src/cmd/bm2 $root/src/cmd/bm2d $root/src/vendor/dateku $root/src/vendor/dcipc $root/src/vendor/fndash $root/src/vendor/fsx $root/src/vendor/logfly $root/src/vendor/notify $root/src/vendor/semver $root/src/vendor/subproc"
}

# The strict type/warning gate that must pass before a commit.
module_check() {
  local root="$1" build_dir="$2" pkgs
  pkgs=$(module_pkgs "$root")
  # shellcheck disable=SC2086
  moon check $pkgs --target-dir "$build_dir" --target native --deny-warn --warn-list +implicit_impl_as_method
}
