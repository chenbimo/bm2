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
  pkill -f "bun (crash|quick|hog|slow|stubborn|other|reuse)\.ts" 2>/dev/null || true
  pkill -f "bun .*notify/receiver.ts" 2>/dev/null || true
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
# 表格解析(row_count / col_values / cell / daemon_cell)与 soak 共用一份。
# shellcheck source=scripts/e2e/table.sh
source "$root/scripts/e2e/table.sh"

wait_status() { # wait_status <app> <expected status> <max attempts>
  for _ in $(seq 1 "$3"); do
    local status
    status=$(cell "$1" STATUS)
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
exec_mode = "fork"
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
(cd "$ACC/crash" && bm2 serve >/dev/null)
(cd "$ACC/quick" && bm2 serve >/dev/null)
sleep 2
check "both projects listed" "2" "$(( $(row_count crash) + $(row_count quick) ))"
check "crash present" "1" "$(row_count crash)"
check "list --json valid array" "1" "$(bm2 list --json | grep -c '^\[.*\]$')"
check "list --json carries app name" "1" "$(bm2 list --json | grep -c '"app_name":"crash"')"
check "list --json name filter" "0" "$(bm2 list --json crash | grep -c '"app_name":"quick"')"
# The human table also reports the daemon itself, above the instance table.
check "list reports the daemon" 1 "$([ -n "$(daemon_cell pid)" ] && echo 1 || echo 0)"
contains "list names the daemon pid" "$state_dir/bm2d.pid" "$(daemon_cell pid)"

echo "===== B. crash loop -> errored ====="
check "crash errored" "errored" "$(wait_status crash errored 60)"
check "crash restart_count 3" "3" "$(cell crash TIMES)"
contains "crash.log reason=exit_code" $state_dir/crash/logs/crash-0.crash.log "reason=exit_code"
contains "crash.log restartCount=3" $state_dir/crash/logs/crash-0.crash.log "restartCount=3"

echo "===== C. clean exit restarts without burning the crash budget ====="
# quick exits cleanly every 100ms: the TIMES column (6th) grows, but a
# clean exit never consumes the crash budget, so it must not hit errored.
check "quick started multiple times" 1 "$([ "$(cell quick TIMES)" -ge 2 ] && echo 1 || echo 0)"
check "quick not errored" "0" "$(bm2 list quick | grep -c 'errored' || true)"
if [ -s $state_dir/quick/logs/quick-0.crash.log ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: quick crash.log should be empty"
else
  PASS=$((PASS + 1)); echo "PASS: quick crash.log empty"
fi

echo "===== D. memory limit -> restart -> errored ====="
write_project hog hog 4221 hog.ts 1 1000
sed -i 's/max_memory_mb = 512/max_memory_mb = 16/; s/max_restarts = 2/max_restarts = 1/' "$ACC/hog/bm2.toml"
(cd "$ACC/hog" && bm2 serve >/dev/null)
check "hog errored" "errored" "$(wait_status hog errored 80)"
check "hog restart_count 2" "2" "$(cell hog TIMES)"
contains "hog crash.log memory_limit" $state_dir/hog/logs/hog-0.crash.log "reason=memory_limit"
contains "hog crash.log rssMb" $state_dir/hog/logs/hog-0.crash.log "rssMb="

echo "===== E. slow app serves HTTP ====="
write_project slow slow 4231 slow.ts 1 1000
(cd "$ACC/slow" && bm2 serve >/dev/null)
check "slow http" "slow slow-0 production 4231 0" "$(wait_http 4231 "slow slow-0 production 4231 0")"

echo "===== F. kill quick unregisters it ====="
bm2 remove -f quick
# The project is gone entirely: querying it reports unknown app.
OUT=$(bm2 list quick 2>&1)
check "quick omitted from list" "unknown app: quick" "$OUT"
check "quick absent from all list" "0" "$(row_count quick)"
check "quick registration removed" "0" "$([ -f "$state_dir/quick/project.json" ] && echo 1 || echo 0)"

echo "===== G. daemon crash adopts running instances ====="
SLOW_PID_BEFORE=$(cell slow PID)
kill -9 "$(cat "$state_dir/bm2d.pid")"
check "stale control-plane file remains after daemon kill" 1 "$([ -f "$state_dir/daemon.endpoint" ] && echo 1 || echo 0)"
sleep 1
bm2 list slow >/dev/null
SLOW_PID_AFTER=$(cell slow PID)
check "slow adopted with same pid" "$SLOW_PID_BEFORE" "$SLOW_PID_AFTER"
check "slow adopted online" "online" "$(cell slow STATUS)"
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
check "pid_conflict status" "errored" "$(cell slow STATUS)"
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
(cd "$ACC/slow" && bm2 serve >/dev/null)
check "slow still on 4231" "slow slow-0 production 4231 0" "$(wait_http 4231 "slow slow-0 production 4231 0")"

echo "===== J. structural change restarts on the new port ====="
sed -i 's/port = 4231/port = 4241/' "$ACC/slow/bm2.toml"
(cd "$ACC/slow" && bm2 serve >/dev/null)
check "structural restart on new port" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"

echo "===== K. structural change accepted when stopped ====="
bm2 remove -f slow
sed -i 's/port = 4241/port = 4241/; s/instances = [0-9]*/instances = 2/' "$ACC/slow/bm2.toml"
(cd "$ACC/slow" && bm2 serve >/dev/null)
check "two instances after rebuild" "2" "$(row_count slow)"
check "rebuilt instance on 4241" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"
check "rebuilt instance on 4242" "slow slow-1 production 4242 1" "$(wait_http 4242 "slow slow-1 production 4242 1")"
bm2 remove -f slow

echo "===== L. kill without app shuts down bm2d ====="
(cd "$ACC/slow" && bm2 serve >/dev/null)
DPID=$(cat "$state_dir/bm2d.pid")
OUT=$(bm2 kill 2>&1)
check "bare kill refused exit" 1 "$?"
check "bare kill refused message" "bm2: refusing to stop bm2d and all apps; use 'bm2 kill -y' to confirm" "$OUT"
check "daemon survives refused kill" 0 "$(kill -0 "$DPID" 2>/dev/null; echo $?)"
check "bare kill response" "bm2d stopping" "$(bm2 kill -y)"
sleep 1
if [ -f "$state_dir/daemon.endpoint" ] || [ -f "$state_dir/bm2d.pid" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: control-plane file not cleaned"
else
  PASS=$((PASS + 1)); echo "PASS: control-plane file cleaned"
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
(cd "$ACC/slow" && bm2 serve >/dev/null)
APID=$(cell slow PID)
DPID=$(cat "$state_dir/bm2d.pid")
check "reload response" "reloaded" "$(bm2 reload)"
sleep 1
NDPID=$(cat "$state_dir/bm2d.pid")
check "daemon pid changed" "changed" "$([ -n "$NDPID" ] && [ "$NDPID" != "$DPID" ] && echo changed || echo same)"
check "app pid preserved" "$APID" "$(cell slow PID)"
check "slow still served" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"
check "detach event logged" 1 "$(grep -c 'daemon_detached' "$state_dir/bm2d.events.jsonl" 2>/dev/null || echo 0)"

echo "===== N. ignored SIGTERM escalates to SIGKILL ====="
bm2 remove -f slow
write_project stubborn stubborn 4251 ignore-term.ts 1 300
(cd "$ACC/stubborn" && bm2 serve >/dev/null)
sleep 1
SPID=$(cell stubborn PID)
# 进程行先出现(停止中→online 的相邻快照对比),最终 `started` 在它后面。
check "restart with ignored SIGTERM" "1" "$(cd "$ACC/stubborn" && bm2 serve | grep -c '^started$')"
sleep 1
check "stubborn old process SIGKILLed" 1 "$(kill -0 "$SPID" 2>/dev/null; echo $?)"
check "stubborn new instance online" "online" "$(cell stubborn STATUS)"
bm2 remove -f stubborn

echo "===== O. external SIGKILL records signal reason ====="
(cd "$ACC/slow" && bm2 serve >/dev/null)
sleep 1
SPID=$(cell slow PID)
kill -9 "$SPID"
sleep 1
contains "signal reason logged" $state_dir/slow/logs/slow-0.crash.log "signal=SIGKILL"
check "slow restarted after signal" "online" "$(wait_status slow online 20)"

echo "===== P. corrupted state file is discarded ====="
DPID=$(cat "$state_dir/bm2d.pid")
APID=$(cell slow PID)
kill -9 "$DPID" "$APID" 2>/dev/null
sleep 0.5
echo 'not json' > "$state_dir/slow/slow-0.json"
(cd "$ACC/slow" && bm2 serve >/dev/null)
sleep 1
check "state_load_failed event" 1 "$(grep -c 'state_load_failed' "$state_dir/bm2d.events.jsonl" 2>/dev/null || echo 0)"
check "slow online after corrupt state" "online" "$(wait_status slow online 20)"

echo "===== R. multi-instance port sequence ====="
bm2 remove -f slow
sed -i 's/instances = [0-9]*/instances = 3/' "$ACC/slow/bm2.toml"
(cd "$ACC/slow" && bm2 serve >/dev/null)
check "three instances online" "3" "$(row_count slow)"
check "instance on 4241" "slow slow-0 production 4241 0" "$(wait_http 4241 "slow slow-0 production 4241 0")"
check "instance on 4242" "slow slow-1 production 4242 1" "$(wait_http 4242 "slow slow-1 production 4242 1")"
check "instance on 4243" "slow slow-2 production 4243 2" "$(wait_http 4243 "slow slow-2 production 4243 2")"
bm2 remove -f slow

echo "===== Q. CLI error paths ====="
OUT=$(bm2 list nosuch 2>&1)
check "unknown app rejected" 1 "$?"
check "unknown app message" "unknown app: nosuch" "$OUT"
OUT=$(bm2 reload extra 2>&1)
check "reload extra arg rejected" 2 "$?"
OUT=$(bm2 kill -y slow 2>&1)
check "kill -y with app rejected" 2 "$?"
OUT=$(bm2 kill slow 2>&1)
check "kill with app rejected" 1 "$?"
if echo "$OUT" | grep -q "kill no longer takes a project" && echo "$OUT" | grep -q "bm2 remove slow"; then
  PASS=$((PASS + 1)); echo "PASS: kill with app points to stop/remove"
else
  FAIL=$((FAIL + 1)); echo "FAIL: kill with app points to stop/remove (got [$OUT])"
fi
mkdir -p "$ACC/noconfig"
OUT=$(cd "$ACC/noconfig" && bm2 serve 2>&1)
check "serve without config rejected" 1 "$?"
check "serve without config message" "bm2: InvalidDocument: cannot read config file: $ACC/noconfig/bm2.toml" "$OUT"
rm -rf "$ACC/noconfig"
# 环境变量只来自 `.env` 文件,动词决定模式。夹具把 NODE_ENV 和 mode 文件里的变量一起
# 回显在响应体里;端口本身就是个 `__VAR__` 占位符 —— 一次验收三件事:模式选中了
# 哪份文件、占位符与扫描出的变量都到了应用里、NODE_ENV 跟着模式走。
mkdir -p "$ACC/withenv"
printf 'Bun.serve({\n  port: Number(process.env.BM2_APP_PORT ?? 3000),\n  fetch() {\n    return new Response(`envapp ${process.env.NODE_ENV} ${process.env.APP_ENV ?? "-"} ${process.env.BM2_APP_INSTANCE}`);\n  },\n});\n' > "$ACC/withenv/envapp.ts"
printf 'name = "withenv"\nscript = "envapp.ts"\ninstances = 1\nport = "__APP_PORT__"\nexec_mode = "fork"\n' > "$ACC/withenv/bm2.toml"
printf 'APP_PORT=4281\nAPP_ENV=prod\n' > "$ACC/withenv/.env.production"
printf 'APP_PORT=4282\nAPP_ENV=dev\n' > "$ACC/withenv/.env.development"
(cd "$ACC/withenv" && bm2 serve >/dev/null 2>&1)
check "serve reads .env.production" "envapp production prod 0" "$(wait_http 4281 'envapp production prod 0')"
bm2 stop withenv >/dev/null 2>&1
# dev 是前台会话,脚本里用 --no-follow 让它跟 serve 一样发完请求就返回。实例数改成 2,
# 验证 dev 只跑一个。
printf 'name = "withenv"\nscript = "envapp.ts"\ninstances = 2\nport = "__APP_PORT__"\nexec_mode = "fork"\n' > "$ACC/withenv/bm2.toml"
(cd "$ACC/withenv" && bm2 dev --no-follow >/dev/null 2>&1)
check "dev reads .env.development" "envapp development dev 0" "$(wait_http 4282 'envapp development dev 0')"
check "dev runs a single instance" "1" "$(row_count withenv)"
check "dev mode in json" "1" "$(bm2 list withenv --json | grep -c '\"mode\":\"development\"')"
bm2 stop withenv >/dev/null 2>&1
# `[env]` 退场了:它现在就是个普通未知字段。
printf 'name = "withenv"\nscript = "slow.ts"\ninstances = 1\nport = 4281\n\n[env]\nAPP_ENV = "production"\n' > "$ACC/withenv/bm2.toml"
OUT=$(cd "$ACC/withenv" && bm2 serve 2>&1)
check "[env] table rejected" 1 "$?"
# 模式决定 NODE_ENV,所以文件里跟它顶牛的值会被当场拒收。
printf 'name = "withenv"\nscript = "slow.ts"\ninstances = 1\nport = 4281\n' > "$ACC/withenv/bm2.toml"
printf 'NODE_ENV=development\n' > "$ACC/withenv/.env"
OUT=$(cd "$ACC/withenv" && bm2 serve 2>&1)
check "NODE_ENV contradiction rejected" 1 "$?"
bm2 remove withenv >/dev/null 2>&1
rm -rf "$ACC/withenv"

echo "===== S. duplicate and conflicting registrations ====="
(cd "$ACC/slow" && bm2 serve >/dev/null)
write_project other other 4241 slow.ts 1 1000
OUT=$(cd "$ACC/other" && bm2 serve 2>&1)
check "port conflict rejected exit" 1 "$?"
if echo "$OUT" | grep -q "port conflict"; then
  PASS=$((PASS + 1)); echo "PASS: port conflict message"
else
  FAIL=$((FAIL + 1)); echo "FAIL: port conflict message (got [$OUT])"
fi
# A different directory claiming the same name is refused: the name is the
# project's identity (state dir, logs, policy), and the message names the file
# that owns it.
write_project slow2 slow 4261 slow.ts 1 1000
OUT=$(cd "$ACC/slow2" && bm2 serve 2>&1)
check "same name from another directory rejected" 1 "$?"
if echo "$OUT" | grep -q "already registered by $ACC/slow/bm2.toml"; then
  PASS=$((PASS + 1)); echo "PASS: name owner reported"
else
  FAIL=$((FAIL + 1)); echo "FAIL: name owner reported (got [$OUT])"
fi
check "the owner keeps its instances" "3" "$(row_count slow)"
# The same directory starting again is the update path, and still works: it
# exits cleanly and the instances keep running under the refreshed config.
(cd "$ACC/slow" && bm2 serve >/dev/null 2>&1)
check "same directory restart still updates" "0" "$?"
check "owner still online after the update" "3" "$(col_values slow STATUS | grep -c '^online$' || true)"
bm2 remove -f slow

echo "===== T. long stop_timeout must not split the daemon ====="
write_project stubborn stubborn 4271 ignore-term.ts 1 5000
(cd "$ACC/stubborn" && bm2 serve >/dev/null)
sleep 1
DPID=$(cat "$state_dir/bm2d.pid")
(cd "$ACC/stubborn" && bm2 serve >/dev/null) &
START_PID=$!
sleep 1
# The daemon keeps answering requests while the long restart is in flight;
# the instance is mid-stop, which is exactly what async start looks like.
check "daemon pid unchanged during restart" "$DPID" "$(cat "$state_dir/bm2d.pid")"
ST=$(cell stubborn STATUS)
if [ "$ST" = "stopping" ] || [ "$ST" = "online" ]; then
  PASS=$((PASS + 1)); echo "PASS: daemon answers during long restart (status=$ST)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: daemon answers during long restart (status=$ST)"
fi
wait "$START_PID"
sleep 5
check "stubborn online after full restart" "online" "$(cell stubborn STATUS)"
bm2 remove -f stubborn

echo "===== V. stop, remove, clean ====="
write_project v1 vapp 4491 slow.ts 1 1000
(cd "$ACC/v1" && bm2 serve >/dev/null)
check "vapp online before stop" "online" "$(cell vapp STATUS)"
bm2 stop vapp
check "stop exits cleanly" "0" "$?"
# Stopped but registered: still listed, with nothing online.
check "a stopped app stays registered" "1" "$(row_count vapp)"
check "nothing online after a stop" "0" "$(col_values vapp STATUS | grep -c '^online$' || true)"
# The stop has to survive a daemon swap, or it is only a pause.
bm2 reload >/dev/null
sleep 2
check "still stopped after the daemon reloaded" "0" "$(col_values vapp STATUS | grep -c '^online$' || true)"
# And start is how it comes back.
(cd "$ACC/v1" && bm2 serve >/dev/null)
sleep 2
check "start resumes a stopped project" "1" "$(col_values vapp STATUS | grep -c '^online$' || true)"
# Retiring frees the name and keeps the logs.
bm2 remove vapp
check "remove exits cleanly" "0" "$?"
check "a retired project leaves the registry" "0" "$(row_count vapp)"
if [ -d "$state_dir/vapp/logs" ]; then
  PASS=$((PASS + 1)); echo "PASS: remove keeps the logs"
else
  FAIL=$((FAIL + 1)); echo "FAIL: remove keeps the logs"
fi
# clean reports the ownerless directory first, and must not touch it.
OUT=$(bm2 clean --dry-run 2>&1)
if echo "$OUT" | grep -q "$state_dir/vapp"; then
  PASS=$((PASS + 1)); echo "PASS: clean --dry-run lists the ownerless directory"
else
  FAIL=$((FAIL + 1)); echo "FAIL: clean --dry-run lists the ownerless directory (got [$OUT])"
fi
if [ -d "$state_dir/vapp" ]; then
  PASS=$((PASS + 1)); echo "PASS: clean --dry-run deletes nothing"
else
  FAIL=$((FAIL + 1)); echo "FAIL: clean --dry-run deleted something"
fi
bm2 clean >/dev/null
if [ -d "$state_dir/vapp" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: clean removes the ownerless directory"
else
  PASS=$((PASS + 1)); echo "PASS: clean removes the ownerless directory"
fi
# The freed name can be registered again.
(cd "$ACC/v1" && bm2 serve >/dev/null)
check "the freed name registers again" "1" "$(row_count vapp)"
# Forced removal takes the whole state directory with it.
write_project v2 vapp2 4492 slow.ts 1 1000
(cd "$ACC/v2" && bm2 serve >/dev/null)
sleep 2
bm2 remove -f vapp2
check "forced remove exits cleanly" "0" "$?"
if [ -d "$state_dir/vapp2" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: remove -f deletes the state directory"
else
  PASS=$((PASS + 1)); echo "PASS: remove -f deletes the state directory"
fi

echo "===== U. log rotation by size ====="
write_project slowback slowback 4291 slow.ts 1 1000
(cd "$ACC/slowback" && bm2 serve >/dev/null)
sleep 1
dd if=/dev/zero of="$state_dir/slowback/logs/slowback-0.out.log" bs=1M count=11 2>/dev/null
# The daemon checks log sizes every 10 s; wait past one check interval.
sleep 12
check "rotated generation exists" 1 "$([ -f "$state_dir/slowback/logs/slowback-0.out.log.1" ] && echo 1 || echo 0)"
SIZE=$(stat -c%s "$state_dir/slowback/logs/slowback-0.out.log")
check "active log truncated below 1 MB" 1 "$([ "$SIZE" -lt 1048576 ] && echo 1 || echo 0)"
check "app unaffected by rotation" "slow slowback-0 production 4291 0" "$(wait_http 4291 "slow slowback-0 production 4291 0")"
bm2 remove -f slowback >/dev/null

echo "===== V. kill app with one instance already dead ====="
write_project twin twin 4292 slow.ts 2 1000
# Zero retry budget so the killed instance lands in errored, not restarting.
sed -i 's/max_restarts = 2/max_restarts = 0/' "$ACC/twin/bm2.toml"
(cd "$ACC/twin" && bm2 serve >/dev/null)
sleep 1
P1=$(cell twin PID)
kill -9 "$P1"
sleep 1
# One instance errored (pid gone), one still online: kill must unregister both.
bm2 remove -f twin >/dev/null
DEAD_GONE=0
for _ in $(seq 1 20); do
  OUT=$(bm2 list twin 2>&1)
  if [ "$OUT" = "unknown app: twin" ]; then
    DEAD_GONE=1
    break
  fi
  sleep 0.5
done
check "half-dead app fully unregistered" "1" "$DEAD_GONE"
check "twin registration removed" "0" "$([ -f "$state_dir/twin/project.json" ] && echo 1 || echo 0)"

echo "===== W. cluster mode is the default and shares one port ====="
mkdir -p "$ACC/reuseapp"
cp "$fixtures/reuse.ts" "$ACC/reuseapp/"
# No exec_mode line: the default must be cluster.
cat > "$ACC/reuseapp/bm2.toml" <<EOF
name = "reuseapp"
script = "reuse.ts"
instances = 3
port = 4301
max_memory_mb = 512
max_restarts = 2
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 1000
EOF
(cd "$ACC/reuseapp" && bm2 serve >/dev/null)
sleep 1
check "three instances online" "3" "$(row_count reuseapp)"
check "all instances share port 4301" "3" "$(col_values reuseapp PORT | grep -c '^4301$' || true)"
check "mode column shows cluster" "3" "$(col_values reuseapp EXEC | grep -c '^cluster$' || true)"
DISTINCT=$(for i in $(seq 1 40); do curl -s --max-time 1 localhost:4301; done | sort -u | wc -l)
check "requests reach multiple instances" 1 "$([ "$DISTINCT" -ge 2 ] && echo 1 || echo 0)"
R_PID=$(cell reuseapp PID)
kill -9 "$R_PID"
sleep 2
check "port still served after one crash" 1 "$(curl -s --max-time 1 localhost:4301 >/dev/null && echo 1 || echo 0)"
check "crashed instance restarted" "3" "$(row_count reuseapp)"
bm2 remove -f reuseapp >/dev/null

echo "===== Y. cluster without reusePort is stopped with a clear reason ====="
mkdir -p "$ACC/noreuse"
cp "$fixtures/slow.ts" "$ACC/noreuse/"
cat > "$ACC/noreuse/bm2.toml" <<EOF
name = "noreuse"
script = "slow.ts"
instances = 2
port = 4311
max_restarts = 0
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 1000
EOF
(cd "$ACC/noreuse" && bm2 serve >/dev/null)
BOTH_ERRORED=0
for _ in $(seq 1 40); do
  LINES=$(row_count noreuse)
  NONERR=$(col_values noreuse STATUS | grep -cv '^errored$' || true)
  if [ "$LINES" = "2" ] && [ "$NONERR" = "0" ]; then BOTH_ERRORED=1; break; fi
  sleep 0.5
done
check "all instances errored on missing reusePort" "1" "$BOTH_ERRORED"
contains "reusePort event logged" "$state_dir/bm2d.events.jsonl" "reuseport_missing"
contains "reusePort crash log" "$state_dir/noreuse/logs/noreuse-0.crash.log" "reuseport_missing"
sleep 2
check "port released after violation stop" "0" "$(ss -ltn | grep -c ':4311 ' || true)"
check "project still registered" "1" "$([ -f "$state_dir/noreuse/project.json" ] && echo 1 || echo 0)"
# Fix the app (reusePort on) and start again: the same project must recover.
cp "$fixtures/reuse.ts" "$ACC/noreuse/"
sed -i 's/script = "slow.ts"/script = "reuse.ts"/' "$ACC/noreuse/bm2.toml"
(cd "$ACC/noreuse" && bm2 serve >/dev/null)
RECOVERED=0
for _ in $(seq 1 40); do
  LINES=$(row_count noreuse)
  ONLINE=$(col_values noreuse STATUS | grep -c '^online$' || true)
  if [ "$LINES" = "2" ] && [ "$ONLINE" = "2" ]; then RECOVERED=1; break; fi
  sleep 0.5
done
check "project recovers after app fix" "1" "$RECOVERED"
check "fixed project serving" 1 "$(curl -s --max-time 1 localhost:4311 >/dev/null && echo 1 || echo 0)"
bm2 remove -f noreuse >/dev/null 2>&1 || true

echo "===== X. runtime below the minimum is rejected ====="
bm2 kill -y >/dev/null 2>&1
sleep 1
mkdir -p "$ACC/fakebin"
printf '#!/bin/sh\necho 0.1.0\n' > "$ACC/fakebin/bun"
chmod +x "$ACC/fakebin/bun"
write_project oldver oldver 4302 slow.ts 1 1000
OUT=$(cd "$ACC/oldver" && PATH="$ACC/fakebin:$PATH" bm2 serve 2>&1)
check "old runtime rejected exit" 1 "$?"
if echo "$OUT" | grep -q "too old" && echo "$OUT" | grep -q "1.4.0"; then
  PASS=$((PASS + 1)); echo "PASS: old runtime rejected message"
else
  FAIL=$((FAIL + 1)); echo "FAIL: old runtime rejected message (got [$OUT])"
fi
check "old runtime project not registered" "0" "$(ls "$state_dir/oldver/project.json" 2>/dev/null | wc -l)"
bm2 kill -y >/dev/null 2>&1 || true

echo "===== Z. state dir permissions are tightened on startup ====="
chmod 755 "$state_dir"
bm2 list >/dev/null 2>&1
check "state dir mode tightened to 0700" "700" "$(stat -c '%a' "$state_dir")"

echo "===== AA. repeated restarts leave no zombies and no fd growth ====="
write_project cycle cycle 4321 slow.ts 1 1000
(cd "$ACC/cycle" && bm2 serve >/dev/null)
sleep 1
DPID=$(cat "$state_dir/bm2d.pid")
FD_FIRST=$(ls "/proc/$DPID/fd" | wc -l)
for _ in 2 3 4 5; do
  (cd "$ACC/cycle" && bm2 serve >/dev/null)
  sleep 1
done
FD_LAST=$(ls "/proc/$DPID/fd" | wc -l)
check "instance online after four restarts" "online" "$(cell cycle STATUS)"
check "no zombie children under bm2d" "0" "$(ps --ppid "$DPID" -o stat= 2>/dev/null | grep -c '^Z' || true)"
check "fd count bounded across restarts" 1 "$([ "$FD_LAST" -le $((FD_FIRST + 3)) ] && echo 1 || echo 0)"
bm2 remove -f cycle >/dev/null

echo "===== AB. a second daemon refuses to start ====="
bm2 list >/dev/null 2>&1
DPID=$(cat "$state_dir/bm2d.pid")
OUT=$(bm2d 2>&1)
check "second daemon refused" 1 "$?"
check "second daemon message" "bm2d: another daemon is already running" "$OUT"
check "first daemon still alive" 0 "$(kill -0 "$DPID" 2>/dev/null; echo $?)"
check "lock file present" 1 "$([ -f "$state_dir/bm2d.lock" ] && echo 1 || echo 0)"

echo "===== AB2. bm2 check validates a project config ====="
write_project ck ck 4341 slow.ts 1 1000
OUT=$(cd "$ACC/ck" && bm2 check 2>&1)
check "check passes a valid config exit" 0 "$?"
check "check summary names the project" 1 "$(echo "$OUT" | grep -c 'config ok: project "ck"')"
check "check summary counts notify disabled" 1 "$(echo "$OUT" | grep -c 'notify: disabled')"
rm "$ACC/ck/slow.ts"
OUT=$(cd "$ACC/ck" && bm2 check 2>&1)
check "check rejects a missing script exit" 1 "$?"
check "check names the missing script" "bm2: script not found: $ACC/ck/slow.ts" "$OUT"
OUT=$(cd "$ACC/ck" && bm2 serve 2>&1)
check "start refuses a missing script exit" 1 "$?"
check "start names the missing script" "bm2: script not found: $ACC/ck/slow.ts" "$OUT"
printf 'name = "ck"
script = "slow.ts"
instances = 1
port = 4341
nope = 1
' > "$ACC/ck/bm2.toml"
OUT=$(cd "$ACC/ck" && bm2 check 2>&1)
check "check rejects an unknown field exit" 1 "$?"
rm -rf "$ACC/ck"

echo "===== AC. notifications: webhook delivery, dedupe, and bm2 notify ====="
bm2 kill -y >/dev/null 2>&1
sleep 1
write_project plain plain 4341 slow.ts 1 1000
# A project whose bm2.toml has no [notify] section has nothing to test.
check "notify without a notify section is rejected" 1 "$(cd "$ACC/plain" && bm2 notify >/dev/null 2>&1; echo $?)"

# A minimal receiver: every POST body is appended to a file.
mkdir -p "$ACC/notify"
cat > "$ACC/notify/receiver.ts" <<'EOF'
import { appendFileSync } from "node:fs";
Bun.serve({
  port: 4321,
  fetch: async (req) => {
    appendFileSync(process.argv[2], (await req.text()) + "\n");
    return new Response("ok");
  },
});
EOF
: > "$ACC/notify/received.log"
bun "$ACC/notify/receiver.ts" "$ACC/notify/received.log" >/dev/null 2>&1 &
RECEIVER=$!
READY=0
for _ in $(seq 1 30); do
  if curl -s --max-time 1 localhost:4321 >/dev/null; then READY=1; break; fi
  sleep 0.2
done
check "notification receiver is up" 1 "$READY"

# The policy belongs to the project, so it goes into that project's bm2.toml.
cat >> "$ACC/plain/bm2.toml" <<EOF

[notify]
enabled = true
dedupe_window_s = 3600
events = ["crash", "errored"]

[[notify.report]]
name = "local"
events = ["crash", "errored"]

[[notify.report.target]]
platform = "webhook"
url = "http://127.0.0.1:4321/hook"
EOF
check "bm2 notify delivers a test message" "webhook: sent" "$(cd "$ACC/plain" && bm2 notify 2>&1)"
contains "test message reached the webhook" "$ACC/notify/received.log" '"event":"lifecycle"'
contains "test message names the host" "$ACC/notify/received.log" '"host"'
check "unknown target is rejected" 1 "$(cd "$ACC/plain" && bm2 notify nosuch >/dev/null 2>&1; echo $?)"

# A crash loop repeats one signature: the dedupe window must collapse it.
write_project notif notif 4331 crash.ts 1 1000
cat >> "$ACC/notif/bm2.toml" <<EOF

[notify]
enabled = true
dedupe_window_s = 3600
events = ["crash", "errored"]

[[notify.report]]
name = "local"
events = ["crash", "errored"]

[[notify.report.target]]
platform = "webhook"
url = "http://127.0.0.1:4321/hook"
EOF
(cd "$ACC/notif" && bm2 serve >/dev/null)
sleep 10
check "one crash notice despite the loop" 1 "$(grep -c '"event":"crash"' "$ACC/notify/received.log" || true)"
check "errored notice delivered" 1 "$(grep -c '"event":"errored"' "$ACC/notify/received.log" || true)"
contains "notice carries the app name" "$ACC/notify/received.log" '"app":"notif"'
contains "notice carries the exit code" "$ACC/notify/received.log" 'exit code 1'
bm2 remove -f notif >/dev/null 2>&1 || true
kill "$RECEIVER" 2>/dev/null
pkill -f "bun .*notify/receiver.ts" 2>/dev/null

echo "===== AD. bm2 upgrade: version check, checksum safety and apply ====="
# A static station serving a release directory. The manifest points at copies of
# the running binaries, so the happy path exercises download -> checksum -> swap ->
# daemon apply while every failure path can be probed without touching anything
# real: a mismatch must abort with the installed binary byte-identical.
mkdir -p "$ACC/release/products/bm2"
cp "$bin_dir/bm2" "$ACC/release/bm2"
cp "$bin_dir/bm2d" "$ACC/release/bm2d"
MANIFEST="$ACC/release/products/bm2/latest.json"
cat > "$ACC/release-server.ts" <<'EOF'
const dir = process.argv[2];
Bun.serve({
  port: 4399,
  fetch: (req) => new Response(Bun.file(dir + new URL(req.url).pathname)),
});
EOF
bun "$ACC/release-server.ts" "$ACC/release" >/dev/null 2>&1 &
STATION=$!
STATION_READY=0
for _ in $(seq 1 30); do
  # curl -f so a 404 cannot pass for "up": the station must really serve files.
  if curl -sf --max-time 1 localhost:4399/bm2 >/dev/null; then
    STATION_READY=1
    break
  fi
  sleep 0.2
done
check "release station is up" 1 "$STATION_READY"

# write_manifest <version> <bm2 sha256> <bm2d sha256>: both platforms, so the
# section runs unchanged on x64 and arm64.
write_manifest() {
  cat > "$MANIFEST" <<EOF
{
  "version": "$1",
  "artifacts": [
    { "name": "bm2", "target": "linux-x64", "url": "http://127.0.0.1:4399/bm2", "sha256": "$2" },
    { "name": "bm2d", "target": "linux-x64", "url": "http://127.0.0.1:4399/bm2d", "sha256": "$3" },
    { "name": "bm2", "target": "linux-arm64", "url": "http://127.0.0.1:4399/bm2", "sha256": "$2" },
    { "name": "bm2d", "target": "linux-arm64", "url": "http://127.0.0.1:4399/bm2d", "sha256": "$3" }
  ]
}
EOF
}
BM2_SHA=$(sha256sum "$ACC/release/bm2" | cut -d' ' -f1)
BM2D_SHA=$(sha256sum "$ACC/release/bm2d" | cut -d' ' -f1)
export BM2_UPDATE_BASE="http://127.0.0.1:4399"

write_manifest "$MV" "$BM2_SHA" "$BM2D_SHA"
check "upgrade reports an up-to-date CLI" "bm2 is up to date ($MV)" "$(bm2 upgrade)"

# Wrong checksum: abort before replacing anything, and leave no staged file.
write_manifest "9.9.9" "0000000000000000000000000000000000000000000000000000000000000000" "$BM2D_SHA"
bm2 upgrade >"$ACC/upgrade-out.txt" 2>&1
check "checksum mismatch exits non-zero" 1 "$?"
contains "checksum mismatch aborts the upgrade" "$ACC/upgrade-out.txt" \
  "checksum mismatch for bm2; update aborted"
check "no staged file left behind" 0 \
  "$([ -f "$bin_dir/.bm2.new" ] && echo 1 || echo 0)"
check "installed binary is byte-identical after the abort" "$BM2_SHA" \
  "$(sha256sum "$bin_dir/bm2" | cut -d' ' -f1)"

# Half a release is not a release: bm2 and bm2d always travel together.
cat > "$MANIFEST" <<EOF
{ "version": "9.9.9", "artifacts": [
  { "name": "bm2", "target": "any", "url": "http://127.0.0.1:4399/bm2", "sha256": "$BM2_SHA" } ] }
EOF
bm2 upgrade >"$ACC/upgrade-out.txt" 2>&1
check "a release missing bm2d is refused" 1 "$?"
contains "the refusal names the platform" "$ACC/upgrade-out.txt" "no release for"

# An unreachable station is reported instead of hanging or half-updating.
BM2_UPDATE_BASE="http://127.0.0.1:1" bm2 upgrade >"$ACC/upgrade-out.txt" 2>&1
check "an unreachable station is refused" 1 "$?"
contains "the refusal names the station" "$ACC/upgrade-out.txt" "cannot reach the release station"

# Happy path: identical binaries under a newer version, so the swap really runs
# without changing behaviour.
write_manifest "9.9.9" "$BM2_SHA" "$BM2D_SHA"
bm2 list >/dev/null 2>&1
DPID_BEFORE=$(cat "$state_dir/bm2d.pid")
bm2 upgrade >"$ACC/upgrade-out.txt" 2>&1
contains "upgrade announces the new version" "$ACC/upgrade-out.txt" "new version 9.9.9 available"
contains "upgrade applies the new daemon" "$ACC/upgrade-out.txt" "updated"
check "the daemon really swapped" 1 \
  "$([ "$DPID_BEFORE" != "$(cat "$state_dir/bm2d.pid")" ] && echo 1 || echo 0)"
check "no backup file left behind" 0 "$([ -f "$bin_dir/bm2.bak" ] && echo 1 || echo 0)"
check "the CLI still runs after replacing itself" "bm2 $MV" "$(bm2 version)"
check "the daemon still answers after the swap" 1 \
  "$([ -n "$(bm2 list)" ] && echo 1 || echo 0)"
# Whatever the paths above did, the shipped version stays the shipped version:
# the artifacts were copies of the running binaries.
check "the installed version is unchanged" "bm2 $MV" "$(bm2 version)"

echo "===== AE. the control plane has a connection ceiling ====="
# Silent connections hold one slot each (until AUTH_TIMEOUT_MS), so a runaway
# local client must be refused instead of growing the daemon without bound — and
# the daemon must stay alive and answer again once the pressure is gone.
bm2 list >/dev/null 2>&1
DPID_BEFORE=$(cat "$state_dir/bm2d.pid")
PORT=$(head -1 "$state_dir/daemon.endpoint")
: > "$ACC/held-fds.txt"
for _ in $(seq 1 70); do
  exec {HELD}<>/dev/tcp/127.0.0.1/$PORT 2>/dev/null || true
  echo "$HELD" >> "$ACC/held-fds.txt"
done
# The daemon logs each refusal from its own task, so wait for the line rather
# than assuming it is already on disk.
REFUSED=0
for _ in $(seq 1 20); do
  if grep -q connection_refused "$state_dir/bm2d.events.jsonl" 2>/dev/null; then
    REFUSED=1
    break
  fi
  sleep 0.2
done
check "the ceiling is reported" 1 "$REFUSED"
check "the daemon survived the flood" "$DPID_BEFORE" "$(cat "$state_dir/bm2d.pid")"
while read -r fd; do eval "exec $fd<&-" 2>/dev/null || true; done < "$ACC/held-fds.txt"
ANSWERED=0
for _ in $(seq 1 20); do
  if bm2 list >/dev/null 2>&1; then ANSWERED=1; break; fi
  sleep 0.5
done
check "the control plane answers again once the slots free up" 1 "$ANSWERED"

echo "===== AF. upgrade with a running app, and upgrade mutual exclusion ====="
export BM2_UPDATE_BASE="http://127.0.0.1:4399"
# An app that ignores SIGTERM: the swap must adopt it, never restart it.
write_project stubborn stubborn 4341 ignore-term.ts 1 1000
(cd "$ACC/stubborn" && bm2 serve >/dev/null)
sleep 1
STUBBORN_PID=$(cell stubborn PID)
check "stubborn app is up before the upgrade" 1 \
  "$([ -n "$STUBBORN_PID" ] && [ "$STUBBORN_PID" != 0 ] && echo 1 || echo 0)"
write_manifest "9.9.9" "$BM2_SHA" "$BM2D_SHA"
bm2 upgrade >"$ACC/upgrade-out.txt" 2>&1
contains "upgrade applies while an app runs" "$ACC/upgrade-out.txt" "updated and applied"
check "the running app keeps its pid across the swap" "$STUBBORN_PID" \
  "$(cell stubborn PID)"
check "the running app is still online" "online" \
  "$(cell stubborn STATUS)"
bm2 remove -f stubborn >/dev/null 2>&1 || true

# Two upgrades at once would stage and swap the same files: the lock is what
# makes the second one stop instead of interleaving.
flock -n "$state_dir/upgrade.lock" -c 'sleep 2' &
LOCKER=$!
sleep 0.3
bm2 upgrade >"$ACC/upgrade-out.txt" 2>&1
check "a concurrent upgrade is refused" 1 "$?"
contains "the refusal names the lock" "$ACC/upgrade-out.txt" \
  "another upgrade is already running"
wait "$LOCKER" 2>/dev/null || true

unset BM2_UPDATE_BASE
kill "$STATION" 2>/dev/null

echo "===== AK. two projects with dead endpoints are both attempted ====="
# Retry state is per message and the next attempt prefers a different project,
# so beta's alert must not wait out alpha's 5s backoff. The first backoff is 5s,
# so seeing both projects' first attempt inside 3s is exactly what rotation buys.
write_project alpha alpha 4391 crash.ts 1 1000
write_project beta beta 4392 crash.ts 1 1000
cat >> "$ACC/alpha/bm2.toml" <<EOF

[notify]
enabled = true
dedupe_window_s = 3600
events = ["crash"]

[[notify.report]]
name = "dead"
events = ["crash"]

[[notify.report.target]]
platform = "webhook"
url = "http://127.0.0.1:4391/hook"
EOF
cat >> "$ACC/beta/bm2.toml" <<EOF

[notify]
enabled = true
dedupe_window_s = 3600
events = ["crash"]

[[notify.report]]
name = "dead"
events = ["crash"]

[[notify.report.target]]
platform = "webhook"
url = "http://127.0.0.1:4392/hook"
EOF
(cd "$ACC/alpha" && bm2 serve >/dev/null)
(cd "$ACC/beta" && bm2 serve >/dev/null)
sleep 3
check "alpha was attempted once, on its first try" 1 \
  "$(grep '"event":"notify_failed"' "$state_dir/bm2d.events.jsonl" | grep -c '"app":"alpha"' || true)"
check "beta was attempted without waiting out alpha's backoff" 1 \
  "$(grep '"event":"notify_failed"' "$state_dir/bm2d.events.jsonl" | grep -c '"app":"beta"' || true)"
bm2 remove -f alpha >/dev/null 2>&1 || true
bm2 remove -f beta >/dev/null 2>&1 || true

echo "===== AI. one instance crashes, its neighbour keeps running ====="
# The same script behaves differently per instance: id 0 exits at once, id 1 serves
# HTTP. Only the crashing instance may spend the project's restart budget.
mkdir -p "$ACC/pair"
cat > "$ACC/pair/half-crash.ts" <<'EOF'
if (Bun.env.BM2_INSTANCE_ID === "0") process.exit(1);
Bun.serve({
  port: Number(Bun.env.BM2_APP_PORT),
  fetch: () => new Response("ok"),
});
EOF
cat > "$ACC/pair/bm2.toml" <<EOF
name = "pair"
script = "half-crash.ts"
instances = 2
port = 4371
exec_mode = "fork"
max_memory_mb = 512
max_restarts = 1
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 1000
EOF
(cd "$ACC/pair" && bm2 serve >/dev/null)
sleep 3
check "the crashing instance errored out" "errored" "$(cell pair STATUS 1)"
check "its neighbour is still online" "online" "$(cell pair STATUS 2)"
check "the neighbour never restarted" "1" "$(cell pair TIMES 2)"
check "the neighbour still serves" "ok" "$(curl -s --max-time 2 localhost:4372)"
bm2 remove -f pair >/dev/null 2>&1 || true

echo "===== AJ. a dead target fails alone; the live one still gets the message ====="
# Two targets, one with nothing listening: the delivery is partial, the live
# target must still receive it, and the CLI must report both outcomes.
cat > "$ACC/live-hook.ts" <<'EOF'
import { appendFileSync } from "node:fs";
Bun.serve({
  port: 4323,
  fetch: async (req) => {
    appendFileSync(process.argv[2], (await req.text()) + "\n");
    return new Response("ok");
  },
});
EOF
: > "$ACC/live-hook.log"
bun "$ACC/live-hook.ts" "$ACC/live-hook.log" >/dev/null 2>&1 &
HOOK=$!
for _ in $(seq 1 30); do
  if curl -s --max-time 1 localhost:4323 >/dev/null; then break; fi
  sleep 0.2
done
mkdir -p "$ACC/mixed"
cp "$fixtures/crash.ts" "$ACC/mixed/"
cat > "$ACC/mixed/bm2.toml" <<EOF
name = "mixed"
script = "crash.ts"
instances = 1
port = 4381
exec_mode = "fork"
max_memory_mb = 512
max_restarts = 2
restart_delay_ms = 100
min_uptime_ms = 60000
stop_timeout_ms = 1000

[notify]
enabled = true
timeout_ms = 2000

[[notify.report]]
name = "mixed"
events = ["crash"]

[[notify.report.target]]
platform = "webhook"
url = "http://127.0.0.1:4323/hook"

[[notify.report.target]]
platform = "webhook"
url = "http://127.0.0.1:4324/hook"
EOF
(cd "$ACC/mixed" && bm2 notify) >"$ACC/mixed-out.txt" 2>&1
check "a partial delivery exits non-zero" 1 "$?"
contains "the live target reports success" "$ACC/mixed-out.txt" "sent"
contains "the dead target reports failure" "$ACC/mixed-out.txt" "failed"
check "the live target received the message" 1 \
  "$(grep -c '"event":"lifecycle"' "$ACC/live-hook.log" || true)"
kill "$HOOK" 2>/dev/null

echo "===== AG. notification retry: fail twice, deliver once ====="
# The engine retries a failed instant alert with a 5s then a 15s backoff. This
# receiver rejects the first two attempts, so passing means the retry path ran and
# a delivery that finally succeeds is not duplicated.
cat > "$ACC/flaky.ts" <<'EOF'
import { appendFileSync } from "node:fs";
const log = process.argv[2];
let attempts = 0;
Bun.serve({
  port: 4322,
  fetch: async (req) => {
    attempts += 1;
    appendFileSync(log, `attempt ${attempts}\n`);
    if (attempts <= 2) return new Response("nope", { status: 500 });
    appendFileSync(log, (await req.text()) + "\n");
    return new Response("ok");
  },
});
EOF
: > "$ACC/flaky.log"
bun "$ACC/flaky.ts" "$ACC/flaky.log" >/dev/null 2>&1 &
FLAKY=$!
for _ in $(seq 1 30); do
  if curl -s --max-time 1 localhost:4322 >/dev/null; then break; fi
  sleep 0.2
done
write_project flaky flaky 4351 crash.ts 1 1000
cat >> "$ACC/flaky/bm2.toml" <<EOF

[notify]
enabled = true
# One alert for the whole crash loop, so the retry counters stay readable.
dedupe_window_s = 3600
events = ["crash"]

[[notify.report]]
name = "flaky"
events = ["crash"]

[[notify.report.target]]
platform = "webhook"
url = "http://127.0.0.1:4322/hook"
EOF
(cd "$ACC/flaky" && bm2 serve >/dev/null)
# 0s fail, 5s fail, 20s succeed: wait past the last backoff.
sleep 26
check "the target was retried twice" 3 "$(grep -c '^attempt' "$ACC/flaky.log")"
check "the alert landed exactly once" 1 "$(grep -c '"event":"crash"' "$ACC/flaky.log")"
contains "the failures were recorded" "$state_dir/bm2d.events.jsonl" '"event":"notify_failed"'
contains "the success was recorded" "$state_dir/bm2d.events.jsonl" '"event":"notify_sent"'
bm2 remove -f flaky >/dev/null 2>&1 || true
kill "$FLAKY" 2>/dev/null

echo "===== AH. email credentials never leave the process before STARTTLS ====="
# A relay that speaks plain SMTP only. bm2 must attempt STARTTLS, and when the
# tunnel cannot be established it must fail — with the credentials still unsent,
# which is the invariant the library documents and the whole reason smtp:// forces
# STARTTLS in the first place.
cat > "$ACC/plain-smtp.ts" <<'EOF'
import { appendFileSync } from "node:fs";
const log = process.argv[2];
Bun.listen({
  hostname: "127.0.0.1",
  port: 4325,
  socket: {
    data(socket, data) {
      const text = data.toString("latin1");
      for (const line of text.split("\r\n")) {
        if (line.length > 0) appendFileSync(log, line + "\n");
      }
      if (text.startsWith("EHLO")) socket.write("250-relay\r\n250 OK\r\n");
      else if (text.startsWith("STARTTLS")) socket.write("220 ready\r\n");
      else if (text.startsWith("QUIT")) socket.write("221 bye\r\n");
      else socket.write("250 OK\r\n");
    },
    open(socket) {
      // A relay speaks first: without the greeting the client waits for a 220
      // that never comes and the session dies on the timeout instead.
      socket.write("220 relay ESMTP\r\n");
    },
    close() {},
  },
});
EOF
: > "$ACC/plain-smtp.log"
bun "$ACC/plain-smtp.ts" "$ACC/plain-smtp.log" >/dev/null 2>&1 &
SMTP=$!
sleep 0.5
write_project mail mail 4361 crash.ts 1 1000
cat >> "$ACC/mail/bm2.toml" <<EOF

[notify]
enabled = true
timeout_ms = 2000
mail_url = "smtp://127.0.0.1:4325"
mail_from = "bm2@example.com"
mail_username = "relay-user"
mail_password = "SMTP-SECRET-PW"

[[notify.report]]
name = "mail"
events = ["crash"]

[[notify.report.target]]
platform = "email"
to = ["ops@example.com"]
EOF
NOTIFY_OUT=$(cd "$ACC/mail" && bm2 notify 2>&1 || true)
printf '%s\n' "$NOTIFY_OUT" > "$ACC/notify-out.txt"
contains "the relay was asked to start TLS" "$ACC/plain-smtp.log" "STARTTLS"
check "no AUTH command was ever sent in the clear" 0 \
  "$(grep -c 'AUTH PLAIN' "$ACC/plain-smtp.log" || true)"
check "the password never reached the relay log" 0 \
  "$(grep -c 'SMTP-SECRET-PW' "$ACC/plain-smtp.log" || true)"
check "the envelope was never reached before TLS" 0 \
  "$(grep -c 'MAIL FROM' "$ACC/plain-smtp.log" || true)"
check "the delivery was reported as failed" 1 \
  "$([ "$(grep -c 'failed' "$ACC/notify-out.txt" || true)" -ge 1 ] && echo 1 || echo 0)"
check "the password never reached the CLI output" 0 \
  "$(grep -c 'SMTP-SECRET-PW' "$ACC/notify-out.txt" || true)"
kill "$SMTP" 2>/dev/null

# Whatever the paths above did, the installed version stays the installed version.
echo ""
echo "e2e results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
