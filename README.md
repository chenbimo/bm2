# bm2

`bm2` is a small Linux process manager for Bun applications, written in MoonBit.

It manages Bun processes only. Nginx remains responsible for reverse proxying and load balancing between instance ports.

## Scope

- Linux only; development and verification target WSL Debian. Non-Linux
  builds refuse to run with a clear message. Requires Linux kernel >= 5.3
  (pidfd process tracking).
- One or more Bun (or Node) applications, each with one or more independent instances.
- Fixed launch command: `<runtime> <script>`.
- Crash restart budget, memory limit, graceful stop timeout, persisted state, and Unix socket control.
- Commands: `start`, `kill`, `refresh`, `version`, `list`.
- `start` always performs a full restart for its target.

It does not manage Nginx, domains, certificates, hot reload, boot startup, or remote administration.

## Requirements

Install these tools inside WSL Debian:

- [MoonBit](https://www.moonbitlang.com/)
- [Bun](https://bun.sh/)
- `curl` for the end-to-end verification script

Open this repository through VS Code Remote-WSL. The repository may remain at `/mnt/c/codes/bm2`; edit it from VS Code and run all commands in the Remote-WSL integrated terminal.

## Build and install

```bash
moon build --target native
mkdir -p ~/.local/bin
cp _build/native/debug/build/cmd/bm2/bm2.exe ~/.local/bin/bm2
cp _build/native/debug/build/cmd/bm2d/bm2d.exe ~/.local/bin/bm2d
chmod +x ~/.local/bin/bm2 ~/.local/bin/bm2d
export PATH="$HOME/.local/bin:$PATH"
```

Both binaries must be on `PATH`: `bm2` launches `bm2d` by name.

## Configuration

Create `bm2.toml` in the directory where you run `bm2`:

```toml
[[apps]]
name = "api"
cwd = "/srv/api"
script = "src/index.ts"
instances = 2
base_port = 3000
```

Every app requires these five fields:

| Field | Meaning |
| --- | --- |
| `name` | Lowercase letters, digits, and hyphens only; unique across apps. |
| `cwd` | Absolute application working directory. |
| `script` | Relative script path inside `cwd`; `..` is forbidden. |
| `instances` | Number of instances; `1..1024`. |
| `base_port` | First instance port; later instances use consecutive ports. |

These optional fields override the built-in defaults:

| Field | Default | Meaning |
| --- | --- | --- |
| `runtime` | `bun` | Runtime executable: `bun` or `node`. |
| `max_memory_mb` | `512` | Maximum VmRSS in MiB; at least `1`. |
| `max_restarts` | `10` | Allowed consecutive abnormal restarts; `0` disables retries. |
| `restart_delay_ms` | `1000` | Delay before an automatic restart. |
| `min_uptime_ms` | `10000` | A clean exit before this duration counts toward the restart budget. |
| `stop_timeout_ms` | `10000` | Grace period after SIGTERM before SIGKILL. |

Port ranges across all apps must not overlap.

## Environment

bm2 passes only `PATH`, `HOME`, and `TMPDIR` from its own environment to managed processes, plus these reserved variables:

- `BM2_APP_NAME`
- `BM2_INSTANCE_ID`
- `BM2_APP_INSTANCE` (the instance number, `"0"` for the first instance; mirrors the PM2 `NODE_APP_INSTANCE` convention so cluster-aware apps can pick a primary)
- `BM2_APP_PORT` (the port assigned to this instance)

Bun automatically loads `.env` files from each application's `cwd`. Do not put application secrets in `bm2.toml`; keep them in the application's environment or `.env` files. Reserved bm2 variables take precedence over values from `apps.env` and `.env`.

## Per-app environment

Each app may provide an optional string-only `[apps.env]` table. bm2 constructs a separate environment for every instance, so variables with the same name in different apps never overwrite each other:

```toml
[[apps]]
name = "api"
cwd = "/srv/api"
script = "src/index.ts"
instances = 2
base_port = 3000

[apps.env]
NODE_ENV = "production"
LOG_LEVEL = "info"
```

The effective precedence is `BM2_APP_NAME` / `BM2_INSTANCE_ID` / `BM2_APP_INSTANCE` / `BM2_APP_PORT`, then `apps.env`, then Bun's project `.env`, then the inherited `PATH`, `HOME`, and `TMPDIR`. Environment names must use letters, digits, and underscores, cannot begin with a digit, and `BM2_APP_NAME`, `BM2_INSTANCE_ID`, `BM2_APP_INSTANCE`, `BM2_APP_PORT`, `PATH`, `HOME`, and `TMPDIR` are reserved. Values must be TOML strings. bm2 never writes environment values to state files, events, crash logs, or CLI output.

## Commands

```bash
bm2 start             # fully restart all configured apps
bm2 start api         # fully restart api only
bm2 kill -y           # SIGKILL all managed apps and exit bm2d (bare `kill` refuses)
bm2 kill api          # immediately SIGKILL api only; bm2d stays running
bm2 refresh           # stop bm2d and start a fresh one; managed apps keep running
bm2 version           # print the bm2 version
bm2 list              # display all instance states
bm2 list api          # display one app
```

A bare `bm2 kill` without `-y` refuses to run and prints a hint, so a stray keystroke cannot take down the daemon and every app at once; `bm2 kill <app>` still needs no confirmation because it only stops one app.

`refresh` swaps in a fresh bm2d (e.g. after installing a new build) without stopping managed apps: the old daemon detaches, the new one adopts the surviving instances with unchanged PIDs.

`list` prints one row per active or abnormal instance, including its PID, port, runtime status, memory, uptime, and the complete project working directory in the final `CWD` column. An app stopped by `bm2 kill <app>` is intentionally omitted; `restarting` and `errored` instances remain visible for diagnosis.

`start` reloads `bm2.toml` every time. While any instance is running, only numeric limits may change (`max_memory_mb`, `max_restarts`, `restart_delay_ms`, `min_uptime_ms`, `stop_timeout_ms`). Changing an app name, working directory, script, instance count, or base port requires `bm2 kill <app>` first.

If a daemon dies abruptly and leaves a stale Unix socket, the next CLI request waits at most three seconds for a response, removes the stale socket, starts one fresh daemon, and retries the request once.

## State and logs

bm2 always stores its socket, PID, state, and management logs in `~/.bm2` for the current Linux user. A user therefore runs one bm2 daemon managing the apps in its `bm2.toml`:

```text
bm2.sock                         # Unix socket, mode 0600
bm2d.pid                         # daemon PID
bm2.events.jsonl                 # CLI connection and retry events
bm2d.log                         # daemon stderr / runtime diagnostics
bm2d.events.jsonl                # daemon and supervisor events
<app>/<app>-<id>.json            # persisted instance state
<app>/logs/<app>-<id>.out.log    # application stdout
<app>/logs/<app>-<id>.error.log  # application stderr
<app>/logs/<app>-<id>.crash.log  # abnormal-exit diagnostics
```

The two `*.events.jsonl` files contain one JSON object per line. They record management metadata only: timestamps, event names, app/instance/PID when applicable, and operational reasons. They do **not** contain environment variable values, protocol payloads, or application output.

Useful commands:

```bash
tail -f ~/.bm2/bm2d.events.jsonl
jq -c . ~/.bm2/bm2.events.jsonl
```

## Verification

From the Remote-WSL terminal, run the complete formatter, static check, native test suite, build, and end-to-end acceptance sequence:

```bash
bash scripts/verify.sh
```

The script requires MoonBit at `~/.moon/bin/moon`, creates temporary fixtures under `/tmp`, and removes their runtime state afterward. It covers crash restart limits, clean exits, memory limits, HTTP readiness, app kill semantics, stale socket recovery and daemon adoption, PID conflict safety, config reload rules, multi-instance rebuilds, daemon shutdown through bare `kill`, and structured event logs.
