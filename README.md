# bm2

`bm2` 是一个用 MoonBit 编写的轻量级 Linux 进程管理器，用于管理 Bun 与 Node.js 应用。

bm2 由命令行工具和后台守护进程组成，命令行通过 Unix socket 下达指令，守护进程持续托管应用进程。

每个用户一个独立守护进程，可同时管理多个项目。

托管能力包括多实例、崩溃自动重启、内存限制、优雅停止与状态持久化。

反向代理与负载均衡交给 Nginx、Caddy 之类的网关负责，bm2 只专注进程托管。

英文文档：[README.en.md](README.en.md)

## bm2与pm2对比

pm2 侧数据为同机 `/tmp` 沙箱、bun 运行时下实测。

| 对比项 | bm2 | pm2 |
| --- | --- | --- |
| 形态 | 原生静态二进制 | Node.js 应用 |
| 额外依赖 | 无 | Node.js 运行时 |
| 体积 | 约 `5.5 MB`（两个二进制） | 约 `23 MB` |
| 文件数量 | `2` 个 | `3036` 个 |
| 空闲守护进程内存 | 约 `2.6 MB` | 约 `50 MB` |
| 命令响应 | 约 `1 ms` | 约 `200~400 ms` |
| 日志轮转 | 内置，`10 MB × 10 代` | 需额外安装 `pm2-logrotate` 模块 |

## 功能特性

- 一个 `bm2.toml` 配置**一个项目**（单个应用，一个或多个独立实例）。
- 崩溃重启预算、内存限制、优雅停止超时、状态持久化、Unix socket 控制。
- 命令：`start`、`kill`、`list`、`reload`、`upgrade`、`version`。
- `start` 总是对其项目执行一次完整重启。

它不管理 Nginx、域名、证书、热重载、开机自启或远程管理。

## 环境要求

- 仅支持 Linux，非 Linux 构建会拒绝运行并给出明确提示。
- 需要 Linux 内核 >= 5.3（pidfd 进程跟踪）。
- [MoonBit](https://www.moonbitlang.com/)（仅安装/升级 bm2 时需要）
- [Bun](https://bun.sh/)
- [Node.js](https://nodejs.org/)（仅 `runtime = "node"` 的项目需要）

## 安装与升级

先安装 MoonBit 工具链：

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
```

再安装 bm2：

```bash
moon install chensuiyi/bm2/...
```

bm2 默认安装到 moon 工具链所在的 `~/.moon/bin`，无需任何 `PATH` 配置。

`bm2` 与 `bm2d` 两个二进制一起安装。

两者都必须留在 `PATH` 中，因为 `bm2` 通过名字启动 `bm2d`。

升级到 mooncakes 上的最新版本，装完自动换入新守护进程：

```bash
bm2 upgrade          # 比对版本、执行 moon install，并自动换入新守护进程
```

## 配置参数

在你运行 `bm2` 的目录创建 `bm2.toml`。

以下为完整模板，包含全部字段与默认值，直接复制修改即可：

```toml
# 项目名：字母开头，后接字母、数字和下划线。
# 同时也是应用名，在所有已注册项目中必须唯一。
name = "api"

# 应用工作目录（绝对路径），默认为 bm2.toml 所在目录。
cwd = "/srv/api"

# 相对 cwd 的脚本路径，禁止 .. 段。
script = "src/index.ts"

# 运行时：bun 或 node。
runtime = "bun"

# 实例数量（1..1024），端口从 port 起连续分配。
instances = 2
port = 3000

# 单实例内存上限（MiB），超过按异常重启处理，至少为 1。
max_memory_mb = 512

# 连续异常重启预算，0 表示首次异常即 errored。
max_restarts = 10

# 自动重启前的延迟（毫秒），崩溃后固定，spawn 失败后按次数递增。
restart_delay_ms = 1000

# 干净退出早于此时长（毫秒）会计入重启预算。
min_uptime_ms = 10000

# SIGTERM 到 SIGKILL 的宽限期（毫秒），最大 60000。
stop_timeout_ms = 10000
```

所有已注册项目的端口范围不得重叠，冲突时 bm2 拒绝启动。

## 环境变量

bm2 只把自己的 `PATH`、`HOME`、`TMPDIR` 传给被管理进程，外加这些保留变量：

- `BM2_APP_NAME`
- `BM2_INSTANCE_ID`
- `BM2_APP_INSTANCE`（实例编号，第一个实例为 `"0"`，与 PM2 的 `NODE_APP_INSTANCE` 约定一致，便于集群感知的应用选择主实例）
- `BM2_APP_PORT`（分配给该实例的端口）
- `NODE_ENV`（恒为 `"production"`：bm2 是生产运行工具，被管理应用可以可靠地检测到自己在 bm2 之下）

应用自身的环境变量由应用与运行时自行加载，bm2 不解析 `.env`，也不参与加载。

bm2 已注入的变量不会被运行时的 `.env` 加载覆盖。

## 命令使用

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

`bm2 list`、`bm2 kill`、`bm2 reload` 和 `bm2 version` 可以在任意目录执行。

只有 `bm2 start` 必须在包含 `bm2.toml` 的目录中运行，因为它要从该配置注册项目。

裸 `bm2 kill`（不带 `-y`）时 bm2 拒绝执行并打印提示。

在项目中（或在另一个使用相同 `name` 的目录中）重新运行 `bm2 start` 会更新配置并执行完整重启，因此修改任何字段——包括实例数量、端口或脚本——都会在下一次 start 时生效。

被 kill 的项目（`bm2 kill <name>`）会完全注销：它从 `bm2 list` 中消失，且不会因守护进程重启而复现。

`reload` 在不停止被管理应用的情况下换入新的 bm2d：旧守护进程分离，新守护进程以不变的 PID 收养仍在运行的实例。

手动替换二进制后使用，`bm2 upgrade` 会自动执行这一步。

`list` 为每个活跃或异常实例打印一行，包括 PID、端口、运行状态、内存、运行时长，以及最后一列 `CWD` 中的完整项目工作目录。

被有意停止的实例会被省略，`restarting` 和 `errored` 实例保持可见，便于运维诊断。

如果守护进程意外崩溃并留下过期的 Unix socket，下一个 CLI 请求会短暂等待响应、删除过期 socket、启动一个新的守护进程，并重试一次请求。

## 状态与日志

bm2 总是把 socket、PID、状态和管理日志存放在当前 Linux 用户的 `~/.bm2` 下。

每个用户一个守护进程，管理所有已注册项目：

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

日志按大小轮转：每个文件达到 10 MB 时轮转，保留十代（`.1` .. `.10`，每个文件最多约 100 MB）。

应用日志与 bm2 自身的管理日志严格分离。

两个 `*.events.jsonl` 文件每行一个 JSON 对象。

它们只记录管理元数据：时间戳、事件名、适用时的应用/实例/PID、运维原因。

它们**不**包含环境变量值、协议载荷或应用输出。

常用命令：

```bash
tail -f ~/.bm2/bm2d.events.jsonl
jq -c . ~/.bm2/bm2d.events.jsonl
```
