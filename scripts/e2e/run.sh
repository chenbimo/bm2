#!/bin/bash
# bm2 end-to-end acceptance. Run through scripts/verify.sh.
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixtures="$root/scripts/e2e/fixtures"
ACC=${BM2_E2E_DIR:-/tmp/bm2-e2e}
real_home=$HOME
export HOME="$ACC/home"
state_dir="$HOME/.bm2"
bin_dir=${BM2_BIN_DIR:?BM2_BIN_DIR must point to bm2 and bm2d binaries}
export PATH="$bin_dir:$real_home/.bun/bin:/usr/bin:/bin"

cleanup() {
  if [ -f "$state_dir/bm2d.pid" ]; then
    kill -TERM "$(cat "$state_dir/bm2d.pid")" 2>/dev/null || true
  fi
  pkill -x bm2 2>/dev/null || true
  rm -rf "$ACC"
}
trap cleanup EXIT

rm -rf "$ACC"
mkdir -p "$ACC" "$HOME"
cp "$fixtures"/*.ts "$ACC/"
cd "$ACC"

PASS=0
FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "PASS: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected [$2] got [$3])"
  fi
}
contains() { # contains <label> <file> <pattern>
  if grep -q "$3" "$2" 2>/dev/null; then
    PASS=$((PASS + 1)); echo "PASS: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (no [$3] in $2)"
  fi
}
wait_http() { # wait_http <port> <expected body>
  for _ in $(seq 1 50); do
    local body
    body=$(curl -s --max-time 1 "localhost:$1")
    if [ "$body" = "$2" ]; then
      printf '%s' "$body"
      return 0
    fi
    sleep 0.1
  done
  printf '%s' "$body"
}
wait_status() { # wait_status <app> <expected status> <max attempts>
  for _ in $(seq 1 "$3"); do
    local status
    status=$(bm2 list "$1" | tail -1 | awk '{print $5}')
    if [ "$status" = "$2" ]; then
      printf '%s' "$status"
      return 0
    fi
    sleep 0.5
  done
  printf '%s' "$status"
}

write_config() { # write_config <slow_stop_timeout> <slow_base_port> <slow_instances>
  cat > bm2.toml <<EOF
[[apps]]
name = "crash"
cwd = "$ACC"
script = "crash.ts"
instances = 1
base_port = 4201
max_memory_mb = 512
max_restarts = 2
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 1000

[[apps]]
name = "quick"
cwd = "$ACC"
script = "quick.ts"
instances = 1
base_port = 4211
max_memory_mb = 512
max_restarts = 5
restart_delay_ms = 100
min_uptime_ms = 50
stop_timeout_ms = 1000

[[apps]]
name = "hog"
cwd = "$ACC"
script = "hog.ts"
instances = 1
base_port = 4221
max_memory_mb = 16
max_restarts = 1
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 1000

[[apps]]
name = "slow"
cwd = "$ACC"
script = "slow.ts"
instances = $3
base_port = $2
max_memory_mb = 512
max_restarts = 2
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = $1

[apps.env]
BM2_E2E_ROLE = "slow"
EOF
}

echo "===== 0. version command ====="
MV=$(sed -nE 's/^version = "([^"]+)"/\1/p' "$root/moon.mod")
check "version output" "bm2 $MV" "$(bm2 version)"

echo "===== A. start all apps ====="
write_config 1000 4231 1
bm2 start
check "start all exit" 0 "$?"
bm2 status >/dev/null 2>&1
check "status command rejected" 2 "$?"
sleep 2

echo "===== B. crash loop -> errored ====="
check "crash errored" "errored" "$(wait_status crash errored 60)"
check "crash restart_count 3" "3" "$(bm2 list crash | tail -1 | awk '{print $6}')"
contains "crash.log reason=exit_code" $state_dir/crash/logs/crash-0.crash.log "reason=exit_code"
contains "crash.log restartCount=3" $state_dir/crash/logs/crash-0.crash.log "restartCount=3"

echo "===== C. clean exit restarts without count ====="
QCOUNT=$(bm2 list quick | tail -1 | awk '{print $6}')
check "quick restart_count stays 0" "0" "$QCOUNT"
if [ -s $state_dir/quick/logs/quick-0.crash.log ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: quick crash.log should be empty"
else
  PASS=$((PASS + 1)); echo "PASS: quick crash.log empty"
fi

echo "===== D. memory limit -> restart -> errored ====="
check "hog errored" "errored" "$(wait_status hog errored 80)"
bm2 list hog
check "hog restart_count 2" "2" "$(bm2 list hog | tail -1 | awk '{print $6}')"
contains "hog crash.log memory_limit" $state_dir/hog/logs/hog-0.crash.log "reason=memory_limit"
contains "hog crash.log rssMb" $state_dir/hog/logs/hog-0.crash.log "rssMb="

echo "===== E. slow app serves HTTP ====="
check "slow http" "slow slow-0 slow 4231 0" "$(wait_http 4231 "slow slow-0 slow 4231 0")"

echo "===== F. kill quick hides it from list ====="
bm2 kill quick
check "quick omitted from list" "no instances" "$(bm2 list quick)"
check "quick absent from all list" "0" "$(bm2 list | grep -c '^quick' || true)"

echo "===== G. daemon restart adopts running instances ====="
SLOW_PID_BEFORE=$(bm2 list slow | tail -1 | awk '{print $3}')
kill -9 "$(cat "$state_dir/bm2d.pid")"
sleep 1
bm2 list slow >/dev/null
SLOW_PID_AFTER=$(bm2 list slow | tail -1 | awk '{print $3}')
check "slow adopted with same pid" "$SLOW_PID_BEFORE" "$SLOW_PID_AFTER"
check "slow adopted online" "online" "$(bm2 list slow | tail -1 | awk '{print $5}')"
check "list cwd" "$ACC" "$(bm2 list slow | tail -1 | awk '{print $NF}')"
contains "adoption event logged" $state_dir/bm2d.events.jsonl "\"event\":\"instance_adopted\""
bm2 kill slow

echo "===== H. pid reuse -> pid_conflict, foreign process untouched ====="
sleep 300 &
FOREIGN=$!
cat > $state_dir/slow/slow-0.json <<EOF
{"app_name":"slow","instance_id":0,"pid":$FOREIGN,"pgid":$FOREIGN,"port":4231,"status":"online","started_at":"2026-07-31T00:00:00.000Z","restart_count":0}
EOF
kill -9 "$(cat "$state_dir/bm2d.pid")" 2>/dev/null
sleep 1
bm2 list slow >/dev/null
check "pid_conflict status" "errored" "$(bm2 list slow | tail -1 | awk '{print $5}')"
contains "pid_conflict crash.log" $state_dir/slow/logs/slow-0.crash.log "reason=pid_conflict"
contains "pid_conflict event logged" $state_dir/bm2d.events.jsonl "\"event\":\"pid_conflict\""
if kill -0 "$FOREIGN" 2>/dev/null; then
  PASS=$((PASS + 1)); echo "PASS: foreign process untouched"
else
  FAIL=$((FAIL + 1)); echo "FAIL: foreign process was killed"
fi
kill "$FOREIGN" 2>/dev/null

echo "===== I. config reload: numeric change accepted while running ====="
write_config 2000 4231 1
bm2 start slow
check "numeric reload start" "started" "$(bm2 start slow)"
check "slow still on 4231" "slow slow-0 slow 4231 0" "$(wait_http 4231 "slow slow-0 slow 4231 0")"

echo "===== J. config reload: structural change rejected while running ====="
write_config 2000 4241 1
OUT=$(bm2 start slow 2>&1)
check "structural reload rejected exit" 1 "$?"
check "structural reload message" "config structure changed; run bm2 kill <app> first" "$OUT"
write_config 2000 4231 1

echo "===== K. structural change accepted when stopped ====="
bm2 kill slow
write_config 1000 4241 2
bm2 start slow
check "idle rebuild start" "started" "$(bm2 start slow)"
bm2 list slow
check "two instances after rebuild" "2" "$(bm2 list slow | grep -c '^slow')"
check "rebuilt instance on 4241" "slow slow-0 slow 4241 0" "$(wait_http 4241 "slow slow-0 slow 4241 0")"
check "rebuilt instance on 4242" "slow slow-1 slow 4242 1" "$(wait_http 4242 "slow slow-1 slow 4242 1")"
bm2 kill slow

echo "===== L. kill without app shuts down bm2d ====="
bm2 start slow >/dev/null
DPID=$(cat "$state_dir/bm2d.pid")
OUT=$(bm2 kill 2>&1)
check "bare kill refused exit" 1 "$?"
check "bare kill refused message" "bm2: refusing to stop bm2d and all apps; use 'bm2 kill -y' to confirm" "$OUT"
check "daemon survives refused kill" 0 "$(kill -0 "$DPID" 2>/dev/null; echo $?)"
check "bare kill response" "bm2d stopping" "$(bm2 kill -y)"
sleep 1
if [ -S "$state_dir/bm2.sock" ] || [ -f "$state_dir/bm2d.pid" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: sock/pid file not cleaned"
else
  PASS=$((PASS + 1)); echo "PASS: sock and pid file cleaned"
fi
if kill -0 "$DPID" 2>/dev/null; then
  FAIL=$((FAIL + 1)); echo "FAIL: bm2d still running"
else
  PASS=$((PASS + 1)); echo "PASS: bm2d exited"
fi
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 localhost:4241 || true)
check "slow killed by daemon shutdown" "000" "$CODE"

echo "===== M. refresh swaps daemon while apps keep running ====="
write_config 1000 4241 1
bm2 start slow >/dev/null
APID=$(bm2 list slow | sed -n '2p' | awk '{print $3}')
DPID=$(cat "$state_dir/bm2d.pid")
check "refresh response" "refreshed" "$(bm2 refresh)"
sleep 1
NDPID=$(cat "$state_dir/bm2d.pid")
check "daemon pid changed" "changed" "$([ -n "$NDPID" ] && [ "$NDPID" != "$DPID" ] && echo changed || echo same)"
check "app pid preserved" "$APID" "$(bm2 list slow | sed -n '2p' | awk '{print $3}')"
check "slow still served" "slow slow-0 slow 4241 0" "$(wait_http 4241 "slow slow-0 slow 4241 0")"
check "detach event logged" 1 "$(grep -c 'daemon_detached' "$state_dir/bm2d.events.jsonl" 2>/dev/null || echo 0)"

echo "===== N. ignored SIGTERM escalates to SIGKILL ====="
bm2 kill slow
cat > bm2.toml <<EOF
[[apps]]
name = "stubborn"
cwd = "$ACC"
script = "ignore-term.ts"
instances = 1
base_port = 4251
max_memory_mb = 512
max_restarts = 0
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 300
EOF
bm2 start stubborn >/dev/null
sleep 1
SPID=$(bm2 list stubborn | sed -n '2p' | awk '{print $3}')
check "restart with ignored SIGTERM" "started" "$(bm2 start stubborn)"
sleep 1
check "stubborn old process SIGKILLed" 1 "$(kill -0 "$SPID" 2>/dev/null; echo $?)"
check "stubborn new instance online" "online" "$(bm2 list stubborn | sed -n '2p' | awk '{print $5}')"
bm2 kill stubborn

echo "===== O. external SIGKILL records signal reason ====="
write_config 1000 4241 1
bm2 start slow >/dev/null
sleep 1
SPID=$(bm2 list slow | sed -n '2p' | awk '{print $3}')
kill -9 "$SPID"
sleep 1
contains "signal reason logged" $state_dir/slow/logs/slow-0.crash.log "signal=SIGKILL"
check "slow restarted after signal" "online" "$(wait_status slow online 20)"

echo "===== P. corrupted state file is discarded ====="
DPID=$(cat "$state_dir/bm2d.pid")
APID=$(bm2 list slow | sed -n '2p' | awk '{print $3}')
kill -9 "$DPID" "$APID" 2>/dev/null
sleep 0.5
echo 'not json' > "$state_dir/slow/slow-0.json"
bm2 start slow >/dev/null
sleep 1
check "state_load_failed event" 1 "$(grep -c 'state_load_failed' "$state_dir/bm2d.events.jsonl" 2>/dev/null || echo 0)"
check "slow online after corrupt state" "online" "$(wait_status slow online 20)"

echo "===== R. multi-instance port sequence ====="
bm2 kill slow
write_config 1000 4261 3
bm2 start slow >/dev/null
check "three instances online" "3" "$(bm2 list slow | grep -c '^slow')"
check "instance on 4261" "slow slow-0 slow 4261 0" "$(wait_http 4261 "slow slow-0 slow 4261 0")"
check "instance on 4262" "slow slow-1 slow 4262 1" "$(wait_http 4262 "slow slow-1 slow 4262 1")"
check "instance on 4263" "slow slow-2 slow 4263 2" "$(wait_http 4263 "slow slow-2 slow 4263 2")"
bm2 kill slow

echo "===== Q. CLI error paths ====="
OUT=$(bm2 list nosuch 2>&1)
check "unknown app rejected" 1 "$?"
check "unknown app message" "unknown app: nosuch" "$OUT"
OUT=$(bm2 refresh extra 2>&1)
check "refresh extra arg rejected" 2 "$?"
OUT=$(bm2 kill -y slow 2>&1)
check "kill -y with app rejected" 2 "$?"
mkdir -p "$ACC/noconfig"
OUT=$(cd "$ACC/noconfig" && bm2 list 2>&1)
check "missing config rejected" 1 "$?"
check "missing config message" "bm2: InvalidDocument: cannot read config file: $ACC/noconfig/bm2.toml" "$OUT"
rm -rf "$ACC/noconfig"

echo "===== S1. long stop_timeout must not split the daemon (H1) ====="
bm2 kill slow
cat > bm2.toml <<EOF
[[apps]]
name = "stubborn"
cwd = "$ACC"
script = "ignore-term.ts"
instances = 1
base_port = 4271
max_memory_mb = 512
max_restarts = 0
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 5000
EOF
bm2 start stubborn >/dev/null
sleep 1
DPID1=$(cat "$state_dir/bm2d.pid")
check "restart waits past 3s CLI timeout" "started" "$(bm2 start stubborn)"
DPID2=$(cat "$state_dir/bm2d.pid")
check "daemon pid unchanged" "$DPID1" "$DPID2"
check "single daemon for this config" 1 "$(pgrep -f "$ACC/bm2.toml" | wc -l)"
bm2 kill stubborn

echo "===== S2. idle client connection must not freeze daemon (H2) ====="
write_config 1000 4281 1
bm2 start slow >/dev/null
sleep 1
BM2_SOCK="$state_dir/bm2.sock" ~/.bun/bin/bun -e '
const s = await Bun.connect({ unix: process.env.BM2_SOCK, socket: {} });
setTimeout(() => process.exit(0), 6000);
' &
BPID=$!
sleep 1
DPID1=$(cat "$state_dir/bm2d.pid")
timeout 8 bm2 list slow >/dev/null 2>&1
check "daemon answers while idle client connected" 0 "$?"
DPID2=$(cat "$state_dir/bm2d.pid")
check "daemon not replaced by idle client" "$DPID1" "$DPID2"
wait "$BPID" 2>/dev/null

echo "===== S3. adopted instance death is detected and restarted (H3) ====="
bm2 refresh >/dev/null
sleep 1
APID=$(bm2 list slow | sed -n '2p' | awk '{print $3}')
kill -9 "$APID"
sleep 2
NPID=$(bm2 list slow | sed -n '2p' | awk '{print $3}')
check "adopted instance restarted with new pid" "changed" "$([ -n "$NPID" ] && [ "$NPID" != "$APID" ] && echo changed || echo same)"
contains "adopted crash logged" $state_dir/slow/logs/slow-0.crash.log "signal=SIGKILL"

echo "===== S4. second daemon for same config refused (H4) ====="
timeout 3 "$bin_dir/bm2d" "$ACC/bm2.toml" >/dev/null 2>&1
check "second daemon refused" 1 "$?"

echo "===== T. soak: daemon fd count stable across many requests ====="
write_config 1000 4291 1
bm2 start slow >/dev/null
sleep 1
DPID=$(cat "$state_dir/bm2d.pid")
FD_BEFORE=$(ls "/proc/$DPID/fd" | wc -l)
for _ in $(seq 1 30); do bm2 list slow >/dev/null 2>&1; done
bm2 start slow >/dev/null
for _ in $(seq 1 30); do bm2 list slow >/dev/null 2>&1; done
sleep 1
FD_AFTER=$(ls "/proc/$DPID/fd" | wc -l)
check "daemon fd count stable" "$FD_BEFORE" "$FD_AFTER"

echo "===== summary: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
