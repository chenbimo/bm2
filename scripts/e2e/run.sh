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
  # kill -9 daemon scenarios leave orphaned app processes behind; make
  # sure no fixture process survives into the next run (ports conflict).
  pkill -f "bun (crash|quick|hog|slow|stubborn|other)\.ts" 2>/dev/null || true
  rm -rf "$ACC"
}
trap cleanup EXIT

rm -rf "$ACC"
mkdir -p "$ACC" "$HOME"
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

# write_project <dir> <name> <port> <script> <instances> <stop_timeout>
# Creates one project directory (a single-app bm2.toml) inside $ACC.
write_project() {
  mkdir -p "$ACC/$1"
  cp "$fixtures/$4" "$ACC/$1/"
  cat > "$ACC/$1/bm2.toml" <<EOF
name = "$2"
script = "$4"
instances = $5
port = $3
max_memory_mb = 512
max_restarts = 2
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = $6
EOF
}

echo "===== 0. version command ====="
MV=$(sed -nE 's/^version = "([^"]+)"/\1/p' "$root/moon.mod")
check "version output" "bm2 $MV" "$(bm2 version)"

echo "===== A. multi-project start and aggregated list ====="
write_project crash crash 4201 crash.ts 1 1000
write_project quick quick 4211 quick.ts 1 1000
# quick exits 100ms after start; treat that as a clean exit.
sed -i 's/min_uptime_ms = 60000/min_uptime_ms = 50/' "$ACC/quick/bm2.toml"
(cd "$ACC/crash" && bm2 start >/dev/null)
(cd "$ACC/quick" && bm2 start >/dev/null)
sleep 2
check "both projects listed" "2" "$(bm2 list | grep -cE '^(crash|quick) ')"
check "crash present" "1" "$(bm2 list | grep -c '^crash ')"

echo "===== B. crash loop -> errored ====="
check "crash errored" "errored" "$(wait_status crash errored 60)"
check "crash restart_count 3" "3" "$(bm2 list crash | tail -1 | awk '{print $6}')"
contains "crash.log reason=exit_code" $state_dir/crash/logs/crash-0.crash.log "reason=exit_code"
contains "crash.log restartCount=3" $state_dir/crash/logs/crash-0.crash.log "restartCount=3"

echo "===== C. clean exit restarts without burning the crash budget ====="
# quick exits cleanly every 100ms: the TIMES column (6th) grows, but a
# clean exit never consumes the crash budget, so it must not hit errored.
check "quick started multiple times" 1 "$([ "$(bm2 list quick | tail -1 | awk '{print $6}')" -ge 2 ] && echo 1 || echo 0)"
check "quick not errored" "0" "$(bm2 list quick | grep -c 'errored' || true)"
if [ -s $state_dir/quick/logs/quick-0.crash.log ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: quick crash.log should be empty"
else
  PASS=$((PASS + 1)); echo "PASS: quick crash.log empty"
fi

echo "===== D. memory limit -> restart -> errored ====="
write_project hog hog 4221 hog.ts 1 1000
sed -i 's/max_memory_mb = 512/max_memory_mb = 16/; s/max_restarts = 2/max_restarts = 1/' "$ACC/hog/bm2.toml"
(cd "$ACC/hog" && bm2 start >/dev/null)
check "hog errored" "errored" "$(wait_status hog errored 80)"
check "hog restart_count 2" "2" "$(bm2 list hog | tail -1 | awk '{print $6}')"
contains "hog crash.log memory_limit" $state_dir/hog/logs/hog-0.crash.log "reason=memory_limit"
contains "hog crash.log rssMb" $state_dir/hog/logs/hog-0.crash.log "rssMb="

echo "===== E. slow app serves HTTP ====="
write_project slow slow 4231 slow.ts 1 1000
(cd "$ACC/slow" && bm2 start >/dev/null)
check "slow http" "slow slow-0 production 4231 0" "$(wait_http 4231 "slow slow-0 production 4231 0")"

echo "===== F. kill quick unregisters it ====="
bm2 kill quick
# The project is gone entirely: querying it reports unknown app.
OUT=$(bm2 list quick 2>&1)
check "quick omitted from list" "unknown app: quick" "$OUT"
check "quick absent from all list" "0" "$(bm2 list | grep -c '^quick ' || true)"
check "quick registration removed" "0" "$([ -f "$state_dir/quick/project.json" ] && echo 1 || echo 0)"

echo "===== G. daemon crash adopts running instances ====="
SLOW_PID_BEFORE=$(bm2 list slow | tail -1 | awk '{print $3}')
kill -9 "$(cat "$state_dir/bm2d.pid")"
sleep 1
bm2 list slow >/dev/null
SLOW_PID_AFTER=$(bm2 list slow | tail -1 | awk '{print $3}')
check "slow adopted with same pid" "$SLOW_PID_BEFORE" "$SLOW_PID_AFTER"
check "slow adopted online" "online" "$(bm2 list slow | tail -1 | awk '{print $5}')"
contains "adoption event logged" $state_dir/bm2d.events.jsonl "\"event\":\"instance_adopted\""

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

echo "===== I. numeric config change accepted while running ====="
sed -i 's/stop_timeout_ms = 1000/stop_timeout_ms = 2000/' "$ACC/slow/bm2.toml"
(cd "$ACC/slow" && bm2 start >/dev/null)
check "slow still on 4231" "slow slow-0 production 4231 0" "$(wait_http 4231 "slow slow-0 production 4231 0")"

echo "===== J. structural change restarts on the new port ====="
sed -i 's/port = 4231/port = 4241/' "$ACC/slow/bm2.toml"
(cd "$ACC/slow" && bm2 start >/dev/null)
check "structural restart on new port" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"

echo "===== K. structural change accepted when stopped ====="
bm2 kill slow
sed -i 's/port = 4241/port = 4241/; s/instances = [0-9]*/instances = 2/' "$ACC/slow/bm2.toml"
(cd "$ACC/slow" && bm2 start >/dev/null)
check "two instances after rebuild" "2" "$(bm2 list slow | grep -c '^slow ')"
check "rebuilt instance on 4241" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"
check "rebuilt instance on 4242" "slow slow-1 production 4242 1" "$(wait_http 4242 "slow slow-1 production 4242 1")"
bm2 kill slow

echo "===== L. kill without app shuts down bm2d ====="
(cd "$ACC/slow" && bm2 start >/dev/null)
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
check "all registrations removed on shutdown" "0" "$(find "$state_dir" -name project.json | wc -l)"

echo "===== M. reload swaps daemon while apps keep running ====="
(cd "$ACC/slow" && bm2 start >/dev/null)
APID=$(bm2 list slow | sed -n '2p' | awk '{print $3}')
DPID=$(cat "$state_dir/bm2d.pid")
check "reload response" "reloaded" "$(bm2 reload)"
sleep 1
NDPID=$(cat "$state_dir/bm2d.pid")
check "daemon pid changed" "changed" "$([ -n "$NDPID" ] && [ "$NDPID" != "$DPID" ] && echo changed || echo same)"
check "app pid preserved" "$APID" "$(bm2 list slow | sed -n '2p' | awk '{print $3}')"
check "slow still served" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"
check "detach event logged" 1 "$(grep -c 'daemon_detached' "$state_dir/bm2d.events.jsonl" 2>/dev/null || echo 0)"

echo "===== N. ignored SIGTERM escalates to SIGKILL ====="
bm2 kill slow
write_project stubborn stubborn 4251 ignore-term.ts 1 300
(cd "$ACC/stubborn" && bm2 start >/dev/null)
sleep 1
SPID=$(bm2 list stubborn | sed -n '2p' | awk '{print $3}')
check "restart with ignored SIGTERM" "started" "$(cd "$ACC/stubborn" && bm2 start | head -1)"
sleep 1
check "stubborn old process SIGKILLed" 1 "$(kill -0 "$SPID" 2>/dev/null; echo $?)"
check "stubborn new instance online" "online" "$(bm2 list stubborn | sed -n '2p' | awk '{print $5}')"
bm2 kill stubborn

echo "===== O. external SIGKILL records signal reason ====="
(cd "$ACC/slow" && bm2 start >/dev/null)
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
(cd "$ACC/slow" && bm2 start >/dev/null)
sleep 1
check "state_load_failed event" 1 "$(grep -c 'state_load_failed' "$state_dir/bm2d.events.jsonl" 2>/dev/null || echo 0)"
check "slow online after corrupt state" "online" "$(wait_status slow online 20)"

echo "===== R. multi-instance port sequence ====="
bm2 kill slow
sed -i 's/instances = [0-9]*/instances = 3/' "$ACC/slow/bm2.toml"
(cd "$ACC/slow" && bm2 start >/dev/null)
check "three instances online" "3" "$(bm2 list slow | grep -c '^slow ')"
check "instance on 4241" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"
check "instance on 4242" "slow slow-1 production 4242 1" "$(wait_http 4242 "slow slow-1 production 4242 1")"
check "instance on 4243" "slow slow-2 production 4243 2" "$(wait_http 4243 "slow slow-2 production 4243 2")"
bm2 kill slow

echo "===== Q. CLI error paths ====="
OUT=$(bm2 list nosuch 2>&1)
check "unknown app rejected" 1 "$?"
check "unknown app message" "unknown app: nosuch" "$OUT"
OUT=$(bm2 reload extra 2>&1)
check "reload extra arg rejected" 2 "$?"
OUT=$(bm2 kill -y slow 2>&1)
check "kill -y with app rejected" 2 "$?"
mkdir -p "$ACC/noconfig"
OUT=$(cd "$ACC/noconfig" && bm2 start 2>&1)
check "start without config rejected" 1 "$?"
check "start without config message" "bm2: InvalidDocument: cannot read config file: $ACC/noconfig/bm2.toml" "$OUT"
rm -rf "$ACC/noconfig"
mkdir -p "$ACC/withenv"
cp "$fixtures/slow.ts" "$ACC/withenv/"
printf 'name = "withenv"\nscript = "slow.ts"\ninstances = 1\nport = 4281\n\n[env]\nAPP_ENV = "production"\n' > "$ACC/withenv/bm2.toml"
OUT=$(cd "$ACC/withenv" && bm2 start 2>&1)
check "removed env table rejected exit" 1 "$?"
check "removed env table rejected message" "bm2: InvalidField: root has unknown field env" "$OUT"
rm -rf "$ACC/withenv"

echo "===== S. duplicate and conflicting registrations ====="
(cd "$ACC/slow" && bm2 start >/dev/null)
write_project other other 4241 slow.ts 1 1000
OUT=$(cd "$ACC/other" && bm2 start 2>&1)
check "port conflict rejected exit" 1 "$?"
if echo "$OUT" | grep -q "port conflict"; then
  PASS=$((PASS + 1)); echo "PASS: port conflict message"
else
  FAIL=$((FAIL + 1)); echo "FAIL: port conflict message (got [$OUT])"
fi
# Same-name project in another directory updates the running project.
write_project slow2 slow 4261 slow.ts 1 1000
(cd "$ACC/slow2" && bm2 start >/dev/null)
check "same name updates existing project" "1" "$(bm2 list slow | grep -c '^slow ')"
check "updated instance on 4261" "slow slow-0 production 4261 0" "$(wait_http 4261 "slow slow-0 production 4261 0")"
bm2 kill slow

echo "===== T. long stop_timeout must not split the daemon ====="
write_project stubborn stubborn 4271 ignore-term.ts 1 5000
(cd "$ACC/stubborn" && bm2 start >/dev/null)
sleep 1
DPID=$(cat "$state_dir/bm2d.pid")
(cd "$ACC/stubborn" && bm2 start >/dev/null) &
START_PID=$!
sleep 1
# The daemon keeps answering requests while the long restart is in flight;
# the instance is mid-stop, which is exactly what async start looks like.
check "daemon pid unchanged during restart" "$DPID" "$(cat "$state_dir/bm2d.pid")"
ST=$(bm2 list stubborn | sed -n '2p' | awk '{print $5}')
if [ "$ST" = "stopping" ] || [ "$ST" = "online" ]; then
  PASS=$((PASS + 1)); echo "PASS: daemon answers during long restart (status=$ST)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: daemon answers during long restart (status=$ST)"
fi
wait "$START_PID"
sleep 5
check "stubborn online after full restart" "online" "$(bm2 list stubborn | sed -n '2p' | awk '{print $5}')"
bm2 kill stubborn

echo ""
echo "e2e results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
