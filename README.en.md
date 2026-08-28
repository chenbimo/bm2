# bm2

`bm2` is a small Linux process manager for Bun and Node.js applications, written in MoonBit.

Nginx remains responsible for reverse proxying and load balancing between instance ports.

Chinese version: [README.md](README.md)

## Scope

- Linux only, non-Linux builds refuse to run with a clear message.
- Requires Linux kernel >= 5.3 (pidfd process tracking).
- One `bm2.toml` configures **one project** (a single app with one or more independent instances).
- One bm2 daemon per user manages many projects.
- Fixed launch command: `<runtime> <script>`.
- Crash restart budget, memory limit, graceful stop timeout, persisted state, and Unix socket control.
- Commands: `start`, `kill`, `list`, `reload`, `upgrade`, `version`.
- `start` always performs a full restart for its project.

It does not manage Nginx, domains, certificates, hot reload, boot startup, or remote administration.

## Requirements

- [MoonBit](https://www.moonbitlang.com/) (only needed to install/upgrade bm2)
- [Bun](https://bun.sh/)
- [Node.js](https://nodejs.org/) (only for projects with `runtime = "node"`)

## Install and upgrade

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

## Configuration

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

# Instance count (1..1024), ports are assigned consecutively from `port`.
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
| `instances` | yes | — | `1..1024` |
| `port` | yes | — | `1..65535`, range must not overlap other projects |
| `max_memory_mb` | no | `512` | at least `1` |
| `max_restarts` | no | `10` | `>= 0`, `0` disables retries |
| `restart_delay_ms` | no | `1000` | `>= 0` |
| `min_uptime_ms` | no | `10000` | `>= 0` |
| `stop_timeout_ms` | no | `10000` | `1..60000` |

Port ranges across all registered projects must not overlap.

On a conflict bm2 refuses to start.

## Environment

bm2 passes only `PATH`, `HOME`, and `TMPDIR` from its own environment to managed processes, plus these reserved variables:

- `BM2_APP_NAME`
- `BM2_INSTANCE_ID`
- `BM2_APP_INSTANCE` (the instance number, `"0"` for the first instance, mirrors the PM2 `NODE_APP_INSTANCE` convention so cluster-aware apps can pick a primary)
- `BM2_APP_PORT` (the port assigned to this instance)
- `NODE_ENV` (always `"production"`: bm2 is a production-run tool, so managed apps can reliably detect they are under bm2)

The application's own environment variables are loaded by the application and its runtime.

bm2 does not parse `.env` and takes no part in loading it.

Variables bm2 has already injected are never overwritten by the runtime's `.env` loading.

## Commands

```bash
bm2 start             # register/update the project in the current directory and start it
bm2 kill <name>       # stop one project and unregister it; bm2d stays running
bm2 kill -y           # stop all projects, unregister them and exit bm2d (bare `kill` refuses)
bm2 list [name]       # display all registered project states
bm2 reload            # swap in a fresh bm2d; managed apps keep running
bm2 upgrade           # update bm2 to the latest mooncakes release
bm2 version           # print the bm2 version
```

`start` and `kill <name>` are asynchronous: the daemon answers immediately and the CLI polls until the operation settles, so the daemon never blocks on stop timeouts.

`bm2 list`, `bm2 kill`, `bm2 reload`, and `bm2 version` work from any directory.

Only `bm2 start` must run in the directory containing `bm2.toml`, because it registers the project from that config.

bm2 refuses to run a bare `bm2 kill` without `-y` and prints a hint.

Re-running `bm2 start` in a project (or in another directory with the same `name`) updates the config and performs a full restart, so changing any field — including the instance count, ports, or script — takes effect on the next start.

A killed project (`bm2 kill <name>`) is fully unregistered: it disappears from `bm2 list` and is not revived by a daemon restart.

`reload` swaps in a fresh bm2d without stopping managed apps: the old daemon detaches, the new one adopts the surviving instances with unchanged PIDs.

Use it after replacing binaries manually, `bm2 upgrade` performs this step automatically.

`list` prints one row per active or abnormal instance, including its PID, port, runtime status, memory, uptime, and the complete project working directory in the final `CWD` column.

Intentionally stopped instances are omitted.

`restarting` and `errored` instances remain visible for diagnosis.

If a daemon dies abruptly and leaves a stale Unix socket, the next CLI request waits briefly for a response, removes the stale socket, starts one fresh daemon, and retries the request once.

## Recovery semantics

A started daemon **adopts still-running instances** of registered projects (after a crash or `reload`) but **never starts anything on its own**: projects only run after an explicit `bm2 start`.

Adoption verifies the process's environment carries bm2's reserved variables, so a foreign process (even one launched manually with the same script) is never touched — it is recorded as a `pid_conflict` instead.

## State and logs

bm2 always stores its socket, PID, state, and management logs in `~/.bm2` for the current Linux user.

One daemon per user manages all registered projects:

```text
bm2.sock                         # Unix socket, mode 0600
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
