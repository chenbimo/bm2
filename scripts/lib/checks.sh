#!/bin/bash
# Check helpers shared by scripts/verify.sh and scripts/pre-commit.sh, so the
# invariants they enforce have exactly one implementation.
#
# Source it, then call the functions with the repository root.

# The CLI's VERSION constant must match moon.mod, or `bm2 version` and the
# mooncakes release drift apart. verify.sh and the pre-commit hook both rely
# on this, so it lives here rather than in either caller.
check_version_sync() {
  local root="$1" mv
  mv=$(sed -nE 's/^version = "([^"]+)"/\1/p' "$root/moon.mod")
  if ! grep -q "const VERSION : String = \"$mv\"" "$root/src/cmd/bm2/main.mbt"; then
    echo "VERSION mismatch: moon.mod says $mv but src/cmd/bm2/main.mbt differs"
    return 1
  fi
}
