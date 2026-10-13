#!/bin/bash
# Long-run soak: many register/unregister cycles plus daemon reloads, sampling the
# daemon's fd count, RSS and the state-file count. A single-pass e2e cannot see a
# slow leak; this is where "grows a little every cycle" shows up.
#
# Run from the repository root in WSL:  bash scripts/soak.sh
# Or as part of the release gate:      bash scripts/verify.sh --release
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=${BM2_BUILD_DIR:-$root/_build-wsl}
fixtures="$root/scripts/e2e/fixtures"
ACC=${BM2_SOAK_DIR:-/tmp/bm2-soak}
CYCLES=${BM2_SOAK_CYCLES:-40}
RELOADS=${BM2_SOAK_RELOADS:-6}

# The hook/environment may be any user; probe the known toolchain locations.
if ! command -v moon > /dev/null 2>&1; then
  for candidate in /root/.moon/bin /home/*/.moon/bin "$HOME/.moon/bin"; do
    if [ -x "$candidate/moon" ]; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi

real_home=$HOME
bin_dir=$(mktemp -d "$build_dir/bm2-soak-bin.XXXXXX")
for name in bm2 bm2d; do
  exe=$(find "$build_dir" -name "$name.exe" -printf '%T@ %p\n' |
    sort -rn | head -1 | cut -d' ' -f2-)
  if [ -z "$exe" ]; then
    echo "soak: no built $name.exe under $build_dir (build first)" >&2
    exit 1
  fi
  cp "$exe" "$bin_dir/$name"
done
chmod +x "$bin_dir/bm2" "$bin_dir/bm2d"

rm -rf "$ACC"
mkdir -p "$ACC/home" "$ACC/app"
export HOME="$ACC/home"
state_dir="$HOME/.bm2"
export PATH="$bin_dir:$real_home/.bun/bin:/usr/bin:/bin"
cd "$ACC"
cp "$fixtures/slow.ts" "$ACC/app/"
cat > "$ACC/app/bm2.toml" <<EOF
name = "app"
script = "slow.ts"
instances = 1
port = 4441
exec_mode = "fork"
max_memory_mb = 512
max_restarts = 2
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 1000
EOF

cleanup() {
  (cd "$ACC/app" && bm2 kill -y >/dev/null 2>&1) || true
  pkill -x bm2d 2>/dev/null || true
  pkill -f 'bun .*slow\.ts' 2>/dev/null || true
  rm -rf "$bin_dir"
}
trap cleanup EXIT

SAMPLE_FDS=0
SAMPLE_RSS=0
SAMPLE_FILES=0
sample() { # sample <label>: refresh SAMPLE_* and print them
  local dpid
  dpid=$(cat "$state_dir/bm2d.pid" 2>/dev/null || echo 0)
  SAMPLE_FDS=$(ls /proc/"$dpid"/fd 2>/dev/null | wc -l)
  SAMPLE_RSS=$(awk '/VmRSS/{print $2}' /proc/"$dpid"/status 2>/dev/null || echo 0)
  SAMPLE_FILES=$(find "$state_dir" -type f 2>/dev/null | wc -l)
  echo "soak $1: daemon_fds=$SAMPLE_FDS daemon_rss_kb=$SAMPLE_RSS state_files=$SAMPLE_FILES"
}

(cd "$ACC/app" && bm2 start >/dev/null)
sleep 2
sample "warm"
WARM_FDS=$SAMPLE_FDS
WARM_RSS=$SAMPLE_RSS
WARM_FILES=$SAMPLE_FILES

for i in $(seq 1 "$CYCLES"); do
  bm2 kill app >/dev/null 2>&1 || true
  (cd "$ACC/app" && bm2 start >/dev/null)
  if [ $((i % 10)) -eq 0 ]; then sample "cycle$i"; fi
done
online=$(bm2 list | grep -c '^app ' || true)
[ "$online" = "1" ] || {
  echo "soak: the app is not online after $CYCLES cycles (matched $online)" >&2
  exit 1
}

for i in $(seq 1 "$RELOADS"); do
  bm2 reload >/dev/null 2>&1
  sleep 1
  sample "reload$i"
done
online=$(bm2 list | grep -c '^app ' || true)
[ "$online" = "1" ] || {
  echo "soak: the app is not online after $RELOADS reloads (matched $online)" >&2
  exit 1
}
http=$(curl -s --max-time 3 localhost:4441 || true)
[ "$http" = "slow app-0 production 4441 0" ] || {
  echo "soak: the app stopped answering (got '$http')" >&2
  exit 1
}

# Growth checks: a healthy daemon keeps its descriptor count flat, its RSS within
# noise, and its state-file count bounded (the same names are rewritten each
# cycle).
[ "$SAMPLE_FDS" -le "$WARM_FDS" ] || {
  echo "soak: daemon descriptors grew from $WARM_FDS to $SAMPLE_FDS" >&2
  exit 1
}
[ "$SAMPLE_RSS" -le $((WARM_RSS * 2)) ] || {
  echo "soak: daemon RSS grew from $WARM_RSS kB to $SAMPLE_RSS kB" >&2
  exit 1
}
[ "$SAMPLE_FILES" -le $((WARM_FILES + 2)) ] || {
  echo "soak: state files grew from $WARM_FILES to $SAMPLE_FILES" >&2
  exit 1
}

echo "soak: ok ($CYCLES cycles, $RELOADS reloads; app online and answering)"
