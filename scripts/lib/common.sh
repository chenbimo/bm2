#!/bin/bash
# Shared helpers for the verification gate and the git hooks.
#
# Single-module repository: bm2 is the only module, and `moon fmt` / `moon check`
# without package arguments cover every package under src/ — no registry needed.

# The strict type/warning gate that must pass before a commit.
module_check() {
  local build_dir="$1"
  moon check --target-dir "$build_dir" --target native --deny-warn --warn-list +implicit_impl_as_method
}
