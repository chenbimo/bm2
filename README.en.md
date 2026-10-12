# bm2

`bm2` is a small Linux process manager for Bun and Node.js applications, written in MoonBit.

bm2 consists of a CLI and a background daemon: the CLI sends commands over a loopback TCP channel guarded by a shared token, and the daemon keeps supervising the application processes.

One daemon per user manages any number of projects.

Supervision covers multiple instances, automatic crash restarts, memory limits, graceful stops, and persisted state.

Reverse proxying and load balancing are left to gateways such as Nginx or Caddy, bm2 focuses on process supervision alone.

Chinese version: [README.md](README.md)

## bm2 vs pm2

| Dimension | bm2 | pm2 |
| --- | --- | --- |
| Form | native static binaries | Node.js application |
| Extra dependency | none | Node.js runtime |
| Size | about `5.5 MB` (two binaries) | about `23 MB` |
| File count | `2` | `3036` |
| Idle daemon memory | about `2.6 MB` | about `50 MB` |
| CLI response | about `1 ms` | about `200-400 ms` |
| Log rotation | built in, `10 MB × 10 generations` | requires the extra `pm2-logrotate` module |

## Features

- One `bm2.toml` configures **one project** (a single app with one or more independent instances).
- Crash restart budget, memory limit, graceful stop timeout, persisted state, and token-guarded loopback TCP control.
- Commands: `start`, `kill`, `list`, `check`, `reload`, `upgrade`, `version`.
- `start` always performs a full restart for its project.

It does not manage Nginx, domains, certificates, hot reload, boot startup, or remote administration.

## Requirements

- Linux only, non-Linux builds refuse to run with a clear message.
- Requires Linux kernel >= 5.3 (pidfd process tracking).
- [MoonBit](https://www.moonbitlang.com/) (only needed to install/upgrade bm2)
- [Bun](https://bun.sh/), version >= 1.4.0
- [Node.js](https://nodejs.org/), version >= 24.0.0 (only for projects with `runtime = "node"`)

`bm2 start` probes the runtime version and refuses to start with a concrete message when it is below the floor.

The daemon's `PATH` is fixed when it starts: after installing a new runtime, run `bm2 reload` to swap in a fresh daemon before starting the project.

## Install and upgrade

Install the MoonBit toolchain first:

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
```

Then install bm2:

```bash
moon install chensuiyi/bm2/...
```

bm2 installs into `~/.moon/bin`, where the moon toolchain lives, so no `PATH` setup is needed.

Both binaries (`bm2`, `bm2d`) are installed together.

Both must stay on `PATH` because `bm2` launches `bm2d` by name.

To update to the latest mooncakes release and apply it automatically:

```bash
bm2 upgrade          # compares versions, runs moon install, and swaps in the new daemon
```

## Configuration parameters

Create `bm2.toml` in the directory where you run `bm2`.

The template below is complete, with every field and its default, copy it and edit directly:

```toml
# Project name: letter first, then letters, digits and underscores only.
# It is the app name too and must be unique among registered projects.
name = "api"

# Application working directory (absolute), defaults to this file's directory.
cwd = "/srv/api"

# Script path relative to cwd, ".." segments are forbidden.
script = "src/index.ts"

# Runtime: bun or node.
runtime = "bun"

# Execution mode: cluster (default, all instances share the single `port`,
# kernel dispatches connections, the app listener needs reusePort on) or
# fork (consecutive ports from `port`).
exec_mode = "cluster"

# Instance count (1..1024).
instances = 2
port = 3000

# Per-instance memory limit (MiB), exceeding it counts as an abnormal restart.
max_memory_mb = 512

# Consecutive abnormal-restart budget, 0 errors out on the first abnormal exit.
max_restarts = 10

# Delay before an automatic restart (ms), fixed after a crash, growing with retries after a spawn failure.
restart_delay_ms = 1000

# A clean exit earlier than this (ms) counts toward the restart budget.
min_uptime_ms = 10000

# Grace period from SIGTERM to SIGKILL (ms), at most 60000.
stop_timeout_ms = 10000
```

Field overview:

| Field | Required | Default | Constraint |
| --- | --- | --- | --- |
| `name` | yes | — | letter first, then letters/digits/underscores, unique |
| `cwd` | no | config dir | absolute path |
| `script` | yes | — | relative inside `cwd`, `..` forbidden |
| `runtime` | no | `bun` | `bun` or `node` |
| `exec_mode` | no | `cluster` | `fork` or `cluster` |
| `instances` | yes | — | `1..1024` |
| `port` | yes | — | `1..65535`, range must not overlap other projects |
| `max_memory_mb` | no | `512` | at least `1` |
| `max_restarts` | no | `10` | `>= 0`, `0` disables retries |
| `restart_delay_ms` | no | `1000` | `>= 0` |
| `min_uptime_ms` | no | `10000` | `>= 0` |
| `stop_timeout_ms` | no | `10000` | `1..60000` |

By default (cluster) every instance shares the single `port`; with `exec_mode = "fork"` ports are assigned consecutively (`port + instance number`).

Port ranges across all registered projects must not overlap (a cluster project occupies a single port slot).

On a conflict bm2 refuses to start.

Upgrading from 0.3.0: `exec_mode` is new in 0.4.0 and defaults to cluster. Multi-instance apps that do not enable `reusePort` in their listener must either set `exec_mode = "fork"` explicitly (old behavior) or add `reusePort` to enjoy cluster mode (without it the second instance dies on EADDRINUSE).

## Environment

The `[env]` table in `bm2.toml` injects custom environment variables into the application (values must be strings), placed after the root table:

```toml
[env]
MYSQL_HOST = "127.0.0.1"
MYSQL_PORT = "3306"
```

Injection order: whitelisted environment, then `[env]`, then the reserved set last (which cannot be overridden). bun/node never let a `.env` file override an existing variable, so `[env]` values beat whatever env files the project ships.

Otherwise bm2 passes only `PATH`, `HOME`, and `TMPDIR` from its own environment to managed processes, plus these reserved variables:

- `BM2_APP_NAME` (the project name)
- `BM2_INSTANCE_ID` (the instance number, `"0"` for the first instance)
- `BM2_APP_INSTANCE` (same instance number, named after PM2's `NODE_APP_INSTANCE` convention)
- `BM2_APP_PORT` (the port assigned to this instance: always `port` in the default cluster mode, `port` plus the instance number in fork mode)
- `NODE_ENV` (always `"production"`)

In cluster mode (default) all instances get the same port (say `3000`) and the kernel dispatches the connections; in fork mode ports map one-to-one to instance numbers: `BM2_APP_PORT = port + BM2_APP_INSTANCE`, for example with `port = 3000` and `instances = 3` the three instances listen on `3000`, `3001`, and `3002`.

Typical usage inside the application:

- Bind the listen port from `BM2_APP_PORT`, each instance owns one port.
- Treat `BM2_APP_INSTANCE === "0"` as the primary, run migrations or cron jobs on the primary only.
- Branch on `NODE_ENV === "production"` for production behavior.

```js
const PORT = Number(process.env.BM2_APP_PORT ?? 3000);
const isPrimary = process.env.BM2_APP_INSTANCE === "0";

Bun.serve({ port: PORT, fetch: () => new Response("ok") });

if (isPrimary) {
  // primary only: migrations, cron jobs, etc.
}
```

The application's own environment variables are loaded by the application and its runtime.

bm2 does not parse `.env` and takes no part in loading it.

Variables bm2 has already injected are never overwritten by the runtime's `.env` loading.

## Command usage

```bash
bm2 start             # register/update the project in the current directory and start it
bm2 kill <name>       # stop one project and unregister it; bm2d stays running
bm2 kill -y           # stop all projects, unregister them and exit bm2d (bare `kill` refuses)
bm2 list [name]       # display all registered project states; add --json for machine-readable output
bm2 reload            # swap in a fresh bm2d; managed apps keep running
bm2 upgrade           # update bm2 to the latest mooncakes release
bm2 version           # print the bm2 version
```

`start` and `kill <name>` are asynchronous: the daemon answers immediately and the CLI polls until the operation settles, so the daemon never blocks on stop timeouts.

`bm2 list`, `bm2 kill`, `bm2 reload`, and `bm2 version` work from any directory.

Only `bm2 start` must run in the directory containing `bm2.toml`, because it registers the project from that config.

bm2 refuses to run a bare `bm2 kill` without `-y` and prints a hint.

Re-running `bm2 start` in a project (or in another directory with the same `name`) updates the config and performs a full restart, so changing any field — including the instance count, ports, or script — takes effect on the next start.

A killed project (`bm2 kill <name>`) is fully unregistered: it disappears from `bm2 list` and is not revived by a daemon restart. Unregistering removes only the registration; the instance state and logs under `~/.bm2/<name>/` are kept for post-mortem inspection.

Sending SIGTERM to bm2d (for example `systemctl restart`) takes the same path as `bm2 kill -y`: stop every project, unregister them, and exit. Only `bm2 reload` preserves the registrations and the managed instances while swapping in a fresh daemon.

`reload` swaps in a fresh bm2d without stopping managed apps: the old daemon detaches, the new one adopts the surviving instances with unchanged PIDs.

Use it after replacing binaries manually, `bm2 upgrade` performs this step automatically. The CLI and the daemon check each other's protocol revision and tell you to run `bm2 reload` on a mismatch, instead of failing with an error that points nowhere.

`list` prints one row per active or abnormal instance, including its PID, port, execution mode (cluster/fork), runtime status, memory, uptime, and the complete project working directory in the final `CWD` column.

Intentionally stopped instances are omitted.

`restarting` and `errored` instances remain visible for diagnosis.

If a daemon dies abruptly and leaves stale control-plane files behind, the next CLI request waits briefly for a response, removes the stale files, starts one fresh daemon, and retries the request once.

## Load balancing

In the default cluster mode every instance shares one port:

```toml
# exec_mode can be omitted, cluster is the default
instances = 4
port = 3000
```

Cluster mode builds on Linux `SO_REUSEPORT`: each instance listens on the same port and the kernel dispatches connections by connection-tuple hash, giving single-port multi-replica load balancing without a gateway (requires bun >= 1.4.0 or node >= 24.0.0).

Turn on `reusePort` in the application's listener:

```js
const PORT = Number(process.env.BM2_APP_PORT);

// Bun
Bun.serve({ port: PORT, reusePort: true, fetch: () => new Response("ok") });

// Node.js
const http = require("node:http");
http
  .createServer((req, res) => res.end("ok"))
  .listen({ port: PORT, reusePort: true });
```

A crashed instance rejoins the port group after its automatic restart while the others keep serving; the `BM2_APP_INSTANCE === "0"` primary check works the same in cluster mode.

After startup bm2 probes whether the listener really enables `reusePort`: when it does not, the whole project is stopped with every instance `errored` (reason `reuseport_missing`); fix the app and run `bm2 start` again, the registration stays.

Domains, TLS, or cross-machine distribution still call for a gateway, and a cluster project needs just one `server 127.0.0.1:3000;` line.

In fork mode the consecutive ports go to a gateway for load balancing.

bm2 focuses on process supervision alone, reverse proxying and load balancing are left to gateways such as Nginx or Caddy.

Point the gateway's domain at the instances' consecutive ports, update the upstream list after changing the instance count, then reload the gateway.

Nginx example (assuming `instances = 2`, `port = 3000`):

```nginx
upstream bm2_app {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
}

server {
    listen 80;
    server_name example.com;

    location / {
        proxy_pass http://bm2_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy example:

```caddyfile
example.com {
    reverse_proxy 127.0.0.1:3000 127.0.0.1:3001
}
```

## State and logs

bm2 always stores its socket, PID, state, and management logs in `~/.bm2` for the current Linux user (falling back to `/tmp/bm2-<uid>` when `HOME` is unavailable).

One daemon per user manages all registered projects:

```text
daemon.port                      # control-channel port (loopback TCP)
daemon.token                     # control-channel shared token, inside the 0700 dir
bm2d.pid                         # daemon PID
bm2.events.jsonl                 # CLI connection and retry events
bm2d.log                         # daemon stderr / runtime diagnostics
bm2d.events.jsonl                # daemon and supervisor events
<name>/project.json              # registration (config path) per project
<name>/<name>-<id>.json          # persisted instance state
<name>/logs/<name>-<id>.out.log    # application stdout
<name>/logs/<name>-<id>.error.log  # application stderr
<name>/logs/<name>-<id>.crash.log  # abnormal-exit diagnostics
```

Logs are rotated by size: each file rotates at 10 MB and keeps ten generations (`.1` .. `.10`, ~100 MB per file at most).

Application logs stay strictly separate from bm2's own management logs.

The two `*.events.jsonl` files contain one JSON object per line.

They record management metadata only: timestamps, event names, app/instance/PID when applicable, and operational reasons.

They do **not** contain environment variable values, protocol payloads, or application output.

Useful commands:

```bash
tail -f ~/.bm2/bm2d.events.jsonl
jq -c . ~/.bm2/bm2d.events.jsonl
```

## Notifications

bm2 can report what it is doing. Notification config belongs to a **project** and lives in the same `bm2.toml`, under `[notify]`; changes take effect on the next `bm2 start`. A project reports only its own events, to the targets it configured itself.

Delivery is built in (`moonbitlang/async` + `chensuiyi/notify`, HTTPS and SMTP included); no external commands such as `curl` are needed.

```bash
bm2 notify            # run inside the project: test every target it configures
```

### Main section

All `[notify]` fields (unless noted, all optional):

| Field | Meaning | Default |
| --- | --- | --- |
| `enabled` | Master switch | `false` |
| `lang` | Notification copy language: `en` / `zh` (chat messages only; CLI/logs/JSON stay English) | `en` |
| `timeout_ms` | Per-delivery hard timeout (100~60000); also caps how long delivery blocks the supervisor | `5000` |
| `dedupe_window_s` | Event dedupe window in seconds (0~604800): one notification per signature per window; 0 disables. Instant reports only | `3600` |
| `max_per_minute` | Instant-report cap per minute (0~6000); excess dropped and counted; 0 unlimited | `30` |
| `queue_size` | Instant-report queue bound (1~4096); full queue drops newest, keeps oldest | `128` |
| `events` | Event gate (choose from the 10 below; unknown values rejected at parse) | `[]` |
| `threshold_rss_percent` | Alert when RSS reaches this percent of the memory limit (0~100) | `0` |
| `threshold_offline_min` | Alert when an instance stays non-online this long (0~1440) | `0` |
| `threshold_restarts` | Consecutive abnormal restarts before an alert (0~1000) | `0` |
| `start_timeout_ms` | Alert when the port has no listener this long after spawn (0~600000) | `0` |
| `threshold_disk_mb` | Alert when the state filesystem has less free space (0~1048576) | `0` |
| `threshold_storm` | Restarts within a 10-minute window before an alert (0~1000) | `0` |
| `mail_url` | Mail channel SMTP endpoint (`smtp://` / `smtps://`); required before any email target | none |
| `mail_from` | Envelope sender | none |
| `mail_username` / `mail_password` | SMTP auth (optional for relays) | none |

### Report entries `[[notify.report]]`

Each entry = behaviour + endpoint list. Two mutually exclusive kinds:

**Instant** (no `cron`): fires when a subscribed event happens; goes through dedupe, rate limiting, queue and retries.

**Periodic** (`cron` + `template`): renders its template on a cron schedule and delivers straight through — no queue, no dedupe, no rate limiting. `cron` is a standard five-field expression (minute hour day month weekday) supporting `*`, `*/n`, numbers and comma lists; **day-of-month and day-of-week may not both be restricted**. `template` presets:

| template | Content |
| --- | --- |
| `health` | Full check: one line per instance (status/port/memory/peak/CPU/uptime/restarts) plus project totals (online/abnormal/mode/port/disk/load) |
| `stats` | Window summary: same layout, plus memory peak (`peak_mb`) and automatic restarts (`restarts`) since the previous stats push |

```toml
[[notify.report]]
name = "health-poll"
cron = "*/5 * * * *"       # every 5 minutes
template = "health"

[[notify.report]]
name = "daily-stats"
cron = "0 8 * * *"         # every day 08:00
template = "stats"
```

`name` is required and unique within the project; `label` is optional (environment tag). Instant reports may set `events` (overrides the gate) and `min_level` (`info`/`warn`/`error`); periodic reports reject both fields.

### Endpoints `[[notify.report.target]]`

Delivery endpoints of one report. `platform` is one of seven:

| platform | Required | Optional |
| --- | --- | --- |
| `feishu` | `url` | `secret`(signing)、`format` |
| `dingtalk` | `url` | `secret`(signing)、`format` |
| `wecom` | `url` | `format` |
| `slack` | `url` | `format` |
| `discord` | `url` | `format` |
| `webhook` | `url` | `secret`(Bearer)、`format` |
| `email` | `to`(recipients array) | `format`(endpoint/auth/sender come from the mail channel) |

### Events

| Event | Level | Meaning |
| --- | --- | --- |
| `crash` | warn | Abnormal exit or spawn failure, within budget, retrying with backoff |
| `errored` | error | Crash budget exhausted; manual `bm2 start` needed |
| `memory_limit` | warn | RSS exceeded the limit; restarted as abnormal |
| `oom_kill` | warn | SIGKILL with memory near the limit — attributed to the kernel OOM killer |
| `reuseport_missing` | error | Cluster project without `reusePort`; the project is stopped |
| `lifecycle` | info | Project start / stop / kill, and clean-exit restarts |
| `daemon` | info | The daemon started, or a reload finished adopting this project |
| `threshold` | warn | Memory pressure, an instance stuck away from online, restart storms |
| `disk_pressure` | warn | Free space on the state filesystem below threshold |
| `start_timeout` | warn | No listener on the port within the timeout after spawn |
| `report` | — | Removed as an event: scheduled content is expressed via `cron` + `template` |

### Full example

```toml
[notify]
enabled = true
lang = "zh"
dedupe_window_s = 60
max_per_minute = 60
events = ["lifecycle", "daemon", "crash", "errored", "memory_limit",
          "reuseport_missing", "threshold", "oom_kill", "disk_pressure",
          "start_timeout"]
threshold_rss_percent = 80
start_timeout_ms = 30000
threshold_disk_mb = 1024

mail_url = "smtps://smtp.example.com:465"
mail_from = "bm2@example.com"
mail_username = "bm2@example.com"
mail_password = "${BM2_MAIL_PASSWORD}"

# Instant: failures -> main group + on-call mail
[[notify.report]]
name = "failures"
events = ["crash", "errored", "memory_limit", "oom_kill", "disk_pressure", "reuseport_missing"]
min_level = "warn"

[[notify.report.target]]
platform = "feishu"
url = "${BM2_MAIN_WEBHOOK_URL}"

[[notify.report.target]]
platform = "email"
to = ["oncall@example.com"]
min_level = "error"

# Periodic: health poll every 5 minutes -> monitor group
[[notify.report]]
name = "health-poll"
cron = "*/5 * * * *"
template = "health"

[[notify.report.target]]
platform = "feishu"
url = "${BM2_REPORT_WEBHOOK_URL}"

# Periodic: daily stats at 08:00 -> reports group
[[notify.report]]
name = "daily-stats"
cron = "0 8 * * *"
template = "stats"

[[notify.report.target]]
platform = "feishu"
url = "${BM2_STATS_WEBHOOK_URL}"
```

`${VAR}` environment references work on **any string** in this section; an unset variable is a hard parse error naming the variable — never a silent empty value.

### Delivery behaviour

- **Isolated per project**: a project reports only its own events, to its own targets; no `[notify]` means fully silent.
- **Zero credential leakage**: failure reasons, event logs and CLI output never contain a url, secret or password; validation errors name fields and indexes only.
- **Instant reports**: dedupe -> rate limit -> queue (drops newest, keeps oldest) -> retries (5s/15s, up to 3, only when every target failed); successful deliveries are silent.
- **Periodic reports**: delivered on schedule, straight through; failures land in the event log without retries.
- **Chinese copy**: with `lang = "zh"` chat messages render in Chinese — every entry, including `bm2d started`.

