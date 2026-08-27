# bm2

`bm2` is a small Linux process manager for Bun applications, written in MoonBit.

It manages Bun processes only. Nginx remains responsible for reverse proxying and load balancing between instance ports.

## Scope

- Linux only; development and verification target WSL Debian. Non-Linux
  builds refuse to run with a clear message. Requires Linux kernel >= 5.3
  (pidfd process tracking).
- One `bm2.toml` configures **one project** (a single app with one or more
  independent instances). One bm2 daemon per user manages many projects.
- Fixed launch command: `<runtime> <script>`.
- Crash restart budget, memory limit, graceful stop timeout, persisted state, and Unix socket control.
- Commands: `start`, `kill`, `list`, `reload`, `upgrade`, `version`.
- `start` always performs a full restart for its project.

It does not manage Nginx, domains, certificates, hot reload, boot startup, or remote administration.

## Requirements

Install these tools inside WSL Debian:

- [MoonBit](https://www.moonbitlang.com/) (only needed to install/upgrade bm2)
- [Bun](https://bun.sh/)
- `curl` for the end-to-end verification script

Open this repository through VS Code Remote-WSL. The repository may remain at `/mnt/c/codes/bm2`; edit it from VS Code and run all commands in the Remote-WSL integrated terminal.

## Install and upgrade

```bash
moon install chensuiyi/bm2/... --bin ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"
```

Both binaries (`bm2`, `bm2d`) are installed together; both must stay on
`PATH` because `bm2` launches `bm2d` by name.

To update to the latest mooncakes release:

```bash
bm2 upgrade          # compares versions, runs moon install, then:
bm2 reload           # swap in the new daemon without stopping apps
```

## Configuration

Create `bm2.toml` in the directory where you run `bm2`:

```toml
# Project name: letter first, then letters, digits and underscores only.
# It is the app name too and must be unique among registered projects.
name = "api"
cwd = "/srv/api"             # optional; defaults to this file's directory
script = "src/index.ts"
instances = 2
port = 3000
```

Required fields:

| Field | Meaning |
| --- | --- |
| `name` | Project/app name. Letter first, then letters, digits and underscores; unique across all registered projects. |
| `script` | Relative script path inside `cwd`; `..` is forbidden. |
| `instances` | Number of instances; `1..1024`. |
| `port` | First instance port; later instances use consecutive ports. |

Optional fields (with defaults):

| Field | Default | Meaning |
| --- | --- | --- |
| `cwd` | config dir | Absolute application working directory. |
| `runtime` | `bun` | Runtime executable: `bun` or `node`. |
| `max_memory_mb` | `512` | Maximum VmRSS in MiB; at least `1`. |
| `max_restarts` | `10` | Allowed consecutive abnormal restarts; `0` disables retries. |
| `restart_delay_ms` | `1000` | Delay before an automatic restart: fixed after a crash, growing with the retry count after a spawn failure. |
| `min_uptime_ms` | `10000` | A clean exit before this duration counts toward the restart budget. |
| `stop_timeout_ms` | `10000` | Grace period after SIGTERM before SIGKILL; at most `60000`. |

Port ranges across all registered projects must not overlap; a conflicting
`bm2 start` is rejected.

## Environment

bm2 passes only `PATH`, `HOME`, and `TMPDIR` from its own environment to managed processes, plus these reserved variables:

- `BM2_APP_NAME`
- `BM2_INSTANCE_ID`
- `BM2_APP_INSTANCE` (the instance number, `"0"` for the first instance; mirrors the PM2 `NODE_APP_INSTANCE` convention so cluster-aware apps can pick a primary)
- `BM2_APP_PORT` (the port assigned to this instance)
- `NODE_ENV` (always `"production"`: bm2 is a production-run tool, so managed apps can reliably detect they are under bm2)

Bun automatically loads `.env` files from the project's `cwd`. Do not put application secrets in `bm2.toml`; keep them in the application's environment or `.env` files. Reserved bm2 variables are injected explicitly into every instance's environment: `[env]` entries with reserved names are rejected at config parse time, and Bun's automatic `.env` loading never overwrites variables that already exist in the process environment.

Each project may provide an optional string-only `[env]` table. Environment names must use letters, digits, and underscores, cannot begin with a digit, and the reserved names above plus `PATH`/`HOME`/`TMPDIR` are rejected. Values must be TOML strings without NUL characters. bm2 never writes environment values to state files, events, crash logs, or CLI output.

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

`start` and `kill <name>` are asynchronous: the daemon answers immediately
and the CLI polls until the operation settles, so the daemon never blocks
on stop timeouts.

`bm2 list`, `bm2 kill`, `bm2 reload`, and `bm2 version` work from any
directory. Only `bm2 start` must run in the directory containing
`bm2.toml`, because it registers the project from that config. A bare
`bm2 kill` without `-y` refuses to run and prints a hint.

Re-running `bm2 start` in a project (or in another directory with the same
`name`) updates the config and performs a full restart, so changing any
field — including the instance count, ports, or script — takes effect on
the next start. A killed project (`bm2 kill <name>`) is fully unregistered:
it disappears from `bm2 list` and is not revived by a daemon restart.

`reload` swaps in a fresh bm2d (e.g. after `bm2 upgrade`) without stopping
managed apps: the old daemon detaches, the new one adopts the surviving
instances with unchanged PIDs.

`list` prints one row per active or abnormal instance, including its PID,
port, runtime status, memory, uptime, and the complete project working
directory in the final `CWD` column. Intentionally stopped instances are
omitted; `restarting` and `errored` instances remain visible for diagnosis.

If a daemon dies abruptly and leaves a stale Unix socket, the next CLI
request waits briefly for a response, removes the stale socket, starts one
fresh daemon, and retries the request once.

## Recovery semantics

A started daemon **adopts still-running instances** of registered projects
(after a crash or `reload`) but **never starts anything on its own**:
projects only run after an explicit `bm2 start`. Adoption verifies the
process's environment carries bm2's reserved variables, so a foreign
process (even one launched manually with the same script) is never
touched — it is recorded as a `pid_conflict` instead.

## State and logs

bm2 always stores its socket, PID, state, and management logs in `~/.bm2`
for the current Linux user. One daemon per user manages all registered
projects:

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

Logs are rotated by size: each file rotates at 10 MB and keeps ten
generations (`.1` .. `.10`, ~100 MB per file at most). Application logs
stay strictly separate from bm2's own management logs.

The two `*.events.jsonl` files contain one JSON object per line. They
record management metadata only: timestamps, event names, app/instance/PID
when applicable, and operational reasons. They do **not** contain
environment variable values, protocol payloads, or application output.

Useful commands:

```bash
tail -f ~/.bm2/bm2d.events.jsonl
jq -c . ~/.bm2/bm2d.events.jsonl
```

## Verification

From the Remote-WSL terminal, run the complete formatter, static check, native test suite, build, and end-to-end acceptance sequence:

```bash
bash scripts/verify.sh
```

The script requires MoonBit at `~/.moon/bin/moon`, creates temporary fixtures under `/tmp`, and removes their runtime state afterward. It covers multi-project registration and aggregated listing, crash restart limits, clean exits, memory limits, HTTP readiness, kill and unregistration semantics, daemon crash adoption, PID conflict safety, config update rules, multi-instance rebuilds, daemon shutdown through bare `kill`, reload without downtime, and structured event logs.
