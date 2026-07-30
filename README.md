# bm2

`bm2` is a small Linux process manager for Bun applications, written in MoonBit.

It manages Bun processes only. Nginx remains responsible for reverse proxying and load balancing between instance ports.

## Scope

- Linux only; development and verification target WSL Debian.
- One or more Bun applications, each with one or more independent instances.
- Fixed launch command: `bun <script>`.
- Crash restart budget, memory limit, graceful stop timeout, persisted state, and Unix socket control.
- Commands: `start`, `stop`, `kill`, `status`.
- `start` always performs a full restart for its target.

It does not manage Nginx, domains, certificates, non-Bun runtimes, hot reload, boot startup, or remote administration.

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
state_dir = "~/.local/state/bm2"

[[apps]]
name = "api"
cwd = "/srv/api"
script = "src/index.ts"
instances = 2
base_port = 3000
max_memory_mb = 512
max_restarts = 10
restart_delay_ms = 1000
min_uptime_ms = 10000
stop_timeout_ms = 10000
```

`state_dir` is optional. Its default is `$XDG_STATE_HOME/bm2`, or `~/.local/state/bm2` when `XDG_STATE_HOME` is unset.

Every app requires these fields:

| Field | Meaning |
| --- | --- |
| `name` | Lowercase letters, digits, and hyphens only; unique across apps. |
| `cwd` | Absolute application working directory. |
| `script` | Relative Bun script path inside `cwd`; `..` is forbidden. |
| `instances` | Number of instances; at least `1`. |
| `base_port` | First instance port; later instances use consecutive ports. |
| `max_memory_mb` | Maximum VmRSS in MiB; at least `1`. |
| `max_restarts` | Allowed consecutive abnormal restarts; `0` disables retries. |
| `restart_delay_ms` | Delay before an automatic restart. |
| `min_uptime_ms` | A clean exit before this duration counts toward the restart budget. |
| `stop_timeout_ms` | Grace period after SIGTERM before SIGKILL. |

Port ranges across all apps must not overlap.

## Environment

bm2 passes only `PATH`, `HOME`, and `TMPDIR` from its own environment to managed processes, plus these reserved variables:

- `BM2_APP_NAME`
- `BM2_INSTANCE_ID`
- `PORT`

Bun automatically loads `.env` files from each application's `cwd`. Do not put application secrets in `bm2.toml`; keep them in the application's environment or `.env` files. Reserved bm2 variables take precedence over values from `.env`.

## Commands

```bash
bm2 start             # fully restart all configured apps
bm2 start api         # fully restart api only
bm2 stop api          # SIGTERM, then SIGKILL after stop_timeout_ms
bm2 kill api          # immediate SIGKILL
bm2 status            # display all instance states
bm2 status api        # display one app
```

`start` reloads `bm2.toml` every time. While any instance is running, only numeric limits may change (`max_memory_mb`, `max_restarts`, `restart_delay_ms`, `min_uptime_ms`, `stop_timeout_ms`). Changing an app name, working directory, script, instance count, or base port requires stopping the affected applications first.

If a daemon dies abruptly and leaves a stale Unix socket, the next CLI request waits at most three seconds for a response, removes the stale socket, starts one fresh daemon, and retries the request once.

## State and logs

Under `state_dir`:

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
tail -f ~/.local/state/bm2/bm2d.events.jsonl
jq -c . ~/.local/state/bm2/bm2.events.jsonl
```

## Verification

From the Remote-WSL terminal, run the complete formatter, static check, native test suite, build, and end-to-end acceptance sequence:

```bash
bash scripts/verify.sh
```

The script requires MoonBit at `~/.moon/bin/moon`, creates temporary fixtures under `/tmp`, and removes their runtime state afterward. It covers crash restart limits, clean exits, memory limits, HTTP readiness, stop semantics, stale socket recovery and daemon adoption, PID conflict safety, config reload rules, multi-instance rebuilds, graceful daemon shutdown, and structured event logs.
