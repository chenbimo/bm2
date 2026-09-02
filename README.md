# bm2

`bm2` 是一个现代化的 Bun 与 Node.js 进程管理器，基于 MoonBit 编程语言实现。

bm2 由命令行工具和后台守护进程组成，命令行通过 Unix socket 下达指令，守护进程持续托管应用进程。

每个用户一个独立守护进程，可同时管理多个项目。

托管能力包括多实例、崩溃自动重启、内存限制、优雅停止与状态持久化。

反向代理与负载均衡交给 Nginx、Caddy 之类的网关负责，bm2 只专注进程托管。

英文文档：[README.en.md](README.en.md)

## bm2与pm2对比

| 对比项           | bm2                                               | pm2                                    |
| ---------------- | ------------------------------------------------- | -------------------------------------- |
| 形态             | 原生静态二进制                                    | Node.js 应用                           |
| 额外依赖         | 无                                                | Node.js 运行时                         |
| 体积             | 约 `5.5 MB`（两个二进制）                         | 约 `23 MB`                             |
| 文件数量         | `2` 个                                            | `3036` 个                              |
| 空闲守护进程内存 | 约 `2.6 MB`                                       | 约 `50 MB`                             |
| 命令响应         | 约 `1 ms`                                         | 约 `200~400 ms`                        |
| 日志轮转         | 内置，`10 MB × 10 代`                             | 需额外安装 `pm2-logrotate` 模块        |
| 多实例模式       | `fork` 连续端口 + `cluster` 单端口（内核分发）    | `fork` + `cluster`（master 分发）      |
| cluster 分发层   | 内核 `SO_REUSEPORT`，无中间层、无单点             | cluster master 进程，宕机即整应用中断  |
| 守护进程崩溃     | 应用无感继续运行，新守护进程原地收养              | cluster 应用随之中断，恢复需重建进程树 |
| 配置方式         | 静态 TOML，字段强校验，零代码执行                 | `ecosystem.config.js`，可执行任意代码  |
| 环境变量         | 最小白名单 + 保留变量显式注入                     | 继承调用 shell 的完整环境              |
| 崩溃恢复         | pidfd 钉住原进程收养，环境校验防误管              | 守护进程崩溃后按 dump 重建，不收养     |
| 自升级           | `bm2 upgrade`：比对版本、安装、自动换入新守护进程 | npm 手动升级后 `pm2 update` 重载       |

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
- [Bun](https://bun.sh/)，版本 >= 1.4.0
- [Node.js](https://nodejs.org/)，版本 >= 24.0.0（仅 `runtime = "node"` 的项目需要）

`bm2 start` 会实测运行时版本，低于下限时拒绝启动并给出具体版本提示。

守护进程的 `PATH` 在其启动时定格：安装新的运行时后，先执行 `bm2 reload` 换入新守护进程再启动项目。

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

# 执行模式：cluster（默认，所有实例共享同一个 port，由内核分发
# 连接，应用监听需开启 reusePort）或 fork（端口从 port 起连续分配）。
exec_mode = "cluster"

# 实例数量（1..1024）。
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

默认（cluster）所有实例共享同一个 `port`；`exec_mode = "fork"` 时端口从 `port` 起连续分配（`port + 实例编号`）。

所有已注册项目的端口范围不得重叠（cluster 项目只占一个端口槽），冲突时 bm2 拒绝启动。

从 0.3.0 升级注意：`exec_mode` 是 0.4.0 新增字段且默认 cluster。多实例项目若应用未在监听时开启 `reusePort`，升级后要么显式声明 `exec_mode = "fork"` 保持旧行为，要么给应用监听加上 `reusePort` 后享用 cluster（未开启时第二个实例会因端口占用崩溃）。

## 环境变量

bm2 只把自己的 `PATH`、`HOME`、`TMPDIR` 传给被管理进程，外加这些保留变量：

- `BM2_APP_NAME`（项目名）
- `BM2_INSTANCE_ID`（实例编号，第一个实例为 `"0"`）
- `BM2_APP_INSTANCE`（同实例编号，命名对齐 PM2 的 `NODE_APP_INSTANCE` 习惯）
- `BM2_APP_PORT`（分配给该实例的端口：默认（cluster）恒为 `port`，fork 模式等于 `port` 加实例编号）
- `NODE_ENV`（恒为 `"production"`）

cluster 模式（默认）下所有实例拿到同一个端口（如 `3000`），由内核分发连接；fork 模式下端口与实例编号一一对应：`BM2_APP_PORT = port + BM2_APP_INSTANCE`，例如 `port = 3000` 且 `instances = 3` 时，三个实例分别监听 `3000`、`3001`、`3002`。

应用内典型用法：

- 用 `BM2_APP_PORT` 绑定监听端口，多实例各占一个端口。
- 用 `BM2_APP_INSTANCE === "0"` 判断主实例，只在主实例执行数据库迁移、定时任务等一次性逻辑。
- 用 `NODE_ENV === "production"` 走生产分支。

```js
const PORT = Number(process.env.BM2_APP_PORT ?? 3000);
const isPrimary = process.env.BM2_APP_INSTANCE === "0";

Bun.serve({ port: PORT, fetch: () => new Response("ok") });

if (isPrimary) {
  // 只在主实例执行：数据库迁移、定时任务等
}
```

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

`list` 为每个活跃或异常实例打印一行，包括 PID、端口、执行模式（cluster/fork）、运行状态、内存、运行时长，以及最后一列 `CWD` 中的完整项目工作目录。

被有意停止的实例会被省略，`restarting` 和 `errored` 实例保持可见，便于运维诊断。

如果守护进程意外崩溃并留下过期的 Unix socket，下一个 CLI 请求会短暂等待响应、删除过期 socket、启动一个新的守护进程，并重试一次请求。

## 负载均衡

默认的 cluster 模式下，所有实例共享同一个端口：

```toml
# exec_mode 可省略，默认即 cluster
instances = 4
port = 3000
```

cluster 模式基于 Linux `SO_REUSEPORT`：每个实例监听同一个端口，内核按连接四元组哈希分发，无需网关即可实现单端口多副本负载均衡（需要 bun >= 1.4.0 或 node >= 24.0.0）。

应用侧监听时打开 `reusePort`：

```js
const PORT = Number(process.env.BM2_APP_PORT);

// Bun
Bun.serve({ port: PORT, reusePort: true, fetch: () => new Response("ok") });

// Node.js
const http = require("node:http");
http.createServer((req, res) => res.end("ok")).listen({ port: PORT, reusePort: true });
```

实例崩溃重启后重新加入端口组，其余实例不受影响；`BM2_APP_INSTANCE === "0"` 的主实例判断在 cluster 模式下同样可用。

bm2 会在启动后探测监听是否真的开启了 `reusePort`：未开启时整个项目被停止，所有实例进入 `errored`（原因 `reuseport_missing`），修正应用后重新 `bm2 start` 即可，注册不会丢失。

需要域名、TLS 或跨机分发时仍配合网关使用，cluster 项目只需一条 `server 127.0.0.1:3000;`。

fork 模式则用连续端口交给网关做负载均衡。

bm2 只专注进程托管，反向代理与负载均衡交给 Nginx、Caddy 之类的网关。

网关把域名指向实例的连续端口即可，实例增减后同步更新 upstream 列表并 reload 网关。

Nginx 示例（假设 `instances = 2`，`port = 3000`）：

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

Caddy 示例：

```caddyfile
example.com {
    reverse_proxy 127.0.0.1:3000 127.0.0.1:3001
}
```

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
