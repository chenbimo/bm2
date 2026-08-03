# bm2

`bm2` 是一个用 MoonBit 编写的轻量级 Linux 进程管理器，用于管理 Bun 应用。

它只管理 Bun 进程。Nginx 负责反向代理与实例端口之间的负载均衡。

## 范围

- 仅支持 Linux；开发与验证面向 WSL Debian。非 Linux 构建会拒绝运行并给出明确提示。需要 Linux 内核 >= 5.3（pidfd 进程跟踪）。
- 一个 `bm2.toml` 配置**一个项目**（单个应用，一个或多个独立实例）。每个用户一个 bm2 守护进程，可管理多个项目。
- 固定启动命令：`<runtime> <script>`。
- 崩溃重启预算、内存限制、优雅停止超时、状态持久化、Unix socket 控制。
- 命令：`start`、`kill`、`list`、`reload`、`upgrade`、`version`。
- `start` 总是对其项目执行一次完整重启。

它不管理 Nginx、域名、证书、热重载、开机自启或远程管理。

## 环境要求

在 WSL Debian 内安装这些工具：

- [MoonBit](https://www.moonbitlang.com/)（仅安装/升级 bm2 时需要）
- [Bun](https://bun.sh/)
- 端到端验证脚本需要 `curl`

通过 VS Code Remote-WSL 打开本仓库。仓库可以保留在 `/mnt/c/codes/bm2`；在 VS Code 中编辑，并在 Remote-WSL 集成终端中运行所有命令。

## 安装与升级

```bash
moon install chensuiyi/bm2/... --bin ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"
```

`bm2` 与 `bm2d` 两个二进制一起安装；两者都必须留在 `PATH` 中，因为 `bm2` 通过名字启动 `bm2d`。

升级到 mooncakes 上的最新版本：

```bash
bm2 upgrade          # 比对版本并执行 moon install，然后：
bm2 reload           # 在不停止应用的情况下换入新守护进程
```

## 配置

在你运行 `bm2` 的目录创建 `bm2.toml`：

```toml
# 项目名：字母开头，后接字母、数字和下划线。
# 同时也是应用名，在所有已注册项目中必须唯一。
name = "api"
cwd = "/srv/api"             # 可选；默认为此文件所在目录
script = "src/index.ts"
instances = 2
port = 3000
```

必填字段：

| 字段 | 含义 |
| --- | --- |
| `name` | 项目/应用名。字母开头，后接字母、数字和下划线；在所有已注册项目中唯一。 |
| `script` | `cwd` 内的相对脚本路径；禁止 `..`。 |
| `instances` | 实例数量；`1..1024`。 |
| `port` | 第一个实例的端口；后续实例使用连续端口。 |

可选字段（含默认值）：

| 字段 | 默认值 | 含义 |
| --- | --- | --- |
| `cwd` | 配置目录 | 应用工作目录（绝对路径）。 |
| `runtime` | `bun` | 运行时可执行文件：`bun` 或 `node`。 |
| `max_memory_mb` | `512` | 最大 VmRSS（MiB）；至少为 `1`。 |
| `max_restarts` | `10` | 允许的连续异常重启次数；`0` 表示禁用重试。 |
| `restart_delay_ms` | `1000` | 自动重启前的延迟。 |
| `min_uptime_ms` | `10000` | 早于该时长的干净退出会计入重启预算。 |
| `stop_timeout_ms` | `10000` | SIGTERM 到 SIGKILL 之间的宽限期；最大 `60000`。 |

所有已注册项目的端口范围不得重叠；冲突的 `bm2 start` 会被拒绝。

## 环境变量

bm2 只把自己的 `PATH`、`HOME`、`TMPDIR` 传给被管理进程，外加这些保留变量：

- `BM2_APP_NAME`
- `BM2_INSTANCE_ID`
- `BM2_APP_INSTANCE`（实例编号，第一个实例为 `"0"`；与 PM2 的 `NODE_APP_INSTANCE` 约定一致，便于集群感知的应用选择主实例）
- `BM2_APP_PORT`（分配给该实例的端口）
- `NODE_ENV`（恒为 `"production"`：bm2 是生产运行工具，被管理应用可以可靠地检测到自己在 bm2 之下）

Bun 会自动从项目的 `cwd` 加载 `.env` 文件。不要把应用密钥放在 `bm2.toml` 里；请放在应用的环境或 `.env` 文件中。bm2 保留变量优先于 `[env]` 和 `.env` 中的值。

每个项目可提供可选的字符串类型 `[env]` 表。环境变量名必须使用字母、数字和下划线，不能以数字开头，且上述保留名加 `PATH`/`HOME`/`TMPDIR` 会被拒绝。值必须是 TOML 字符串且不含 NUL 字符。bm2 从不把环境变量值写入状态文件、事件、崩溃日志或 CLI 输出。

## 命令

```bash
bm2 start             # 注册/更新当前目录中的项目并启动它
bm2 kill <name>       # 停止一个项目并注销它；bm2d 继续运行
bm2 kill -y           # 停止所有项目、注销它们并退出 bm2d（裸 `kill` 会拒绝执行）
bm2 list [name]       # 显示所有已注册项目的状态
bm2 reload            # 换入新的 bm2d；被管理的应用继续运行
bm2 upgrade           # 把 bm2 升级到 mooncakes 上的最新版本
bm2 version           # 显示 bm2 版本
```

`start` 和 `kill <name>` 是异步的：守护进程立即应答，CLI 轮询直到操作完成，因此守护进程永远不会因停止超时而阻塞。

`bm2 list`、`bm2 kill`、`bm2 reload` 和 `bm2 version` 可以在任意目录执行。只有 `bm2 start` 必须在包含 `bm2.toml` 的目录中运行，因为它要从该配置注册项目。裸 `bm2 kill`（不带 `-y`）会拒绝执行并打印提示。

在项目中（或在另一个使用相同 `name` 的目录中）重新运行 `bm2 start` 会更新配置并执行完整重启，因此修改任何字段——包括实例数量、端口或脚本——都会在下一次 start 时生效。被 kill 的项目（`bm2 kill <name>`）会完全注销：它从 `bm2 list` 中消失，且不会因守护进程重启而复现。

`reload` 在不停止被管理应用的情况下换入新的 bm2d（例如 `bm2 upgrade` 之后）：旧守护进程分离，新守护进程以不变的 PID 收养仍在运行的实例。

`list` 为每个活跃或异常实例打印一行，包括 PID、端口、运行状态、内存、运行时长，以及最后一列 `CWD` 中的完整项目工作目录。被有意停止的实例会被省略；`restarting` 和 `errored` 实例保持可见，便于运维诊断。

如果守护进程意外崩溃并留下过期的 Unix socket，下一个 CLI 请求会短暂等待响应、删除过期 socket、启动一个新的守护进程，并重试一次请求。

## 恢复语义

已启动的守护进程会**收养已注册项目中仍在运行的实例**（崩溃或 `reload` 之后），但**绝不会自行启动任何东西**：项目只会在显式执行 `bm2 start` 之后运行。收养会校验进程环境是否携带 bm2 的保留变量，因此外来进程（即使是用相同脚本手动启动的）也绝不会被触碰——它会被记录为 `pid_conflict`。

## 状态与日志

bm2 总是把 socket、PID、状态和管理日志存放在当前 Linux 用户的 `~/.bm2` 下。每个用户一个守护进程，管理所有已注册项目：

```text
bm2.sock                         # Unix socket，权限 0600
bm2d.pid                         # 守护进程 PID
bm2.events.jsonl                 # CLI 连接与重试事件
bm2d.log                         # 守护进程 stderr / 运行时诊断
bm2d.events.jsonl                # 守护进程与监督事件
<name>/project.json              # 每个项目的注册信息（配置路径）
<name>/<name>-<id>.json          # 持久化的实例状态
<name>/logs/<name>-<id>.out.log    # 应用 stdout
<name>/logs/<name>-<id>.error.log  # 应用 stderr
<name>/logs/<name>-<id>.crash.log  # 异常退出诊断
```

日志按大小轮转：每个文件达到 10 MB 时轮转，保留十代（`.1` .. `.10`，每个文件最多约 100 MB）。应用日志与 bm2 自身的管理日志严格分离。

两个 `*.events.jsonl` 文件每行一个 JSON 对象。它们只记录管理元数据：时间戳、事件名、适用时的应用/实例/PID、运维原因。它们**不**包含环境变量值、协议载荷或应用输出。

常用命令：

```bash
tail -f ~/.bm2/bm2d.events.jsonl
jq -c . ~/.bm2/bm2d.events.jsonl
```

## 验证

在 Remote-WSL 终端运行完整的格式化、静态检查、原生测试套件、构建和端到端验收序列：

```bash
bash scripts/verify.sh
```

该脚本要求 MoonBit 位于 `~/.moon/bin/moon`，在 `/tmp` 下创建临时 fixture，并在之后清除其运行状态。它覆盖多项目注册与聚合列表、崩溃重启上限、干净退出、内存限制、HTTP 就绪、kill 与注销语义、守护进程崩溃收养、PID 冲突安全、配置更新规则、多实例重建、裸 `kill` 关闭守护进程、reload 不中断服务以及结构化事件日志。
