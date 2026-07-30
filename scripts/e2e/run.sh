#!/bin/bash
# bm2 end-to-end acceptance. Run through scripts/verify.sh.
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixtures="$root/scripts/e2e/fixtures"
ACC=${BM2_E2E_DIR:-/tmp/bm2-e2e}
bin_dir=${BM2_BIN_DIR:?BM2_BIN_DIR must point to bm2 and bm2d binaries}
export PATH="$bin_dir:$HOME/.bun/bin:/usr/bin:/bin"

cleanup() {
  if [ -f "$ACC/state/bm2d.pid" ]; then
    kill -TERM "$(cat "$ACC/state/bm2d.pid")" 2>/dev/null || true
  fi
  pkill -x bm2 2>/dev/null || true
  rm -rf "$ACC"
}
trap cleanup EXIT

rm -rf "$ACC"
mkdir -p "$ACC"
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

write_config() { # write_config <slow_stop_timeout> <slow_base_port> <slow_instances>
  cat > bm2.toml <<EOF
state_dir = "$ACC/state"

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
EOF
}

echo "===== A. start all apps ====="
write_config 1000 4231 1
bm2 start
check "start all exit" 0 "$?"
sleep 2

echo "===== B. crash loop -> errored ====="
bm2 status crash
check "crash errored" "errored" "$(bm2 status crash | tail -1 | awk '{print $5}')"
check "crash restart_count 3" "3" "$(bm2 status crash | tail -1 | awk '{print $6}')"
contains "crash.log reason=exit_code" state/crash/logs/crash-0.crash.log "reason=exit_code"
contains "crash.log restartCount=3" state/crash/logs/crash-0.crash.log "restartCount=3"

echo "===== C. clean exit restarts without count ====="
QCOUNT=$(bm2 status quick | tail -1 | awk '{print $6}')
check "quick restart_count stays 0" "0" "$QCOUNT"
if [ -s state/quick/logs/quick-0.crash.log ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: quick crash.log should be empty"
else
  PASS=$((PASS + 1)); echo "PASS: quick crash.log empty"
fi

echo "===== D. memory limit -> restart -> errored ====="
sleep 14
bm2 status hog
check "hog errored" "errored" "$(bm2 status hog | tail -1 | awk '{print $5}')"
check "hog restart_count 2" "2" "$(bm2 status hog | tail -1 | awk '{print $6}')"
contains "hog crash.log memory_limit" state/hog/logs/hog-0.crash.log "reason=memory_limit"
contains "hog crash.log rssMb" state/hog/logs/hog-0.crash.log "rssMb="

echo "===== E. slow app serves HTTP ====="
check "slow http" "slow slow-0" "$(wait_http 4231 "slow slow-0")"

echo "===== F. stop quick (no auto-restart afterwards) ====="
bm2 stop quick
QPID1=$(bm2 status quick | tail -1 | awk '{print $3}')
sleep 1
QPID2=$(bm2 status quick | tail -1 | awk '{print $3}')
check "quick stays stopped" "$QPID1" "$QPID2"
check "quick stopped status" "stopped" "$(bm2 status quick | tail -1 | awk '{print $5}')"

echo "===== G. daemon restart adopts running instances ====="
SLOW_PID_BEFORE=$(bm2 status slow | tail -1 | awk '{print $3}')
kill -9 "$(cat state/bm2d.pid)"
sleep 1
bm2 status slow >/dev/null
SLOW_PID_AFTER=$(bm2 status slow | tail -1 | awk '{print $3}')
check "slow adopted with same pid" "$SLOW_PID_BEFORE" "$SLOW_PID_AFTER"
check "slow adopted online" "online" "$(bm2 status slow | tail -1 | awk '{print $5}')"
contains "stale socket retry logged" state/bm2.events.jsonl "\"event\":\"stale_socket_removed\""
contains "adoption event logged" state/bm2d.events.jsonl "\"event\":\"instance_adopted\""
bm2 stop slow

echo "===== H. pid reuse -> pid_conflict, foreign process untouched ====="
sleep 300 &
FOREIGN=$!
cat > state/slow/slow-0.json <<EOF
{"app_name":"slow","instance_id":0,"pid":$FOREIGN,"pgid":$FOREIGN,"port":4231,"status":"online","started_at":"2026-07-31T00:00:00.000Z","restart_count":0}
EOF
kill -9 "$(cat state/bm2d.pid)" 2>/dev/null
sleep 1
bm2 status slow >/dev/null
check "pid_conflict status" "errored" "$(bm2 status slow | tail -1 | awk '{print $5}')"
contains "pid_conflict crash.log" state/slow/logs/slow-0.crash.log "reason=pid_conflict"
contains "pid_conflict event logged" state/bm2d.events.jsonl "\"event\":\"pid_conflict\""
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
check "slow still on 4231" "slow slow-0" "$(wait_http 4231 "slow slow-0")"

echo "===== J. config reload: structural change rejected while running ====="
write_config 2000 4241 1
OUT=$(bm2 start slow 2>&1)
check "structural reload rejected exit" 1 "$?"
check "structural reload message" "config structure changed; run bm2 stop first" "$OUT"
write_config 2000 4231 1

echo "===== K. structural change accepted when stopped ====="
bm2 stop slow
write_config 1000 4241 2
bm2 start slow
check "idle rebuild start" "started" "$(bm2 start slow)"
bm2 status slow
check "two instances after rebuild" "2" "$(bm2 status slow | grep -c '^slow')"
check "rebuilt instance on 4241" "slow slow-0" "$(wait_http 4241 "slow slow-0")"
check "rebuilt instance on 4242" "slow slow-1" "$(wait_http 4242 "slow slow-1")"
bm2 stop slow

echo "===== L. daemon SIGTERM graceful shutdown ====="
bm2 start slow >/dev/null
DPID=$(cat state/bm2d.pid)
kill -TERM "$DPID"
sleep 3
if [ -S state/bm2.sock ] || [ -f state/bm2d.pid ]; then
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
check "slow stopped by daemon shutdown" "000" "$CODE"

echo "===== summary: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
