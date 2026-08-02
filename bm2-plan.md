# bm2 设计方案：用 MoonBit 管理多个 Bun 进程，Nginx 负责负载均衡

## 背景

当前项目使用 PM2 管理 Bun 服务。

PM2 功能很完整，但对只部署 Bun 项目的 Linux 单机环境来说，能力明显过多。

`bm2` 的目标不是复刻 PM2，也不是替换 Nginx。

它只做一件事：在 Linux 单机上稳定维护多个 Bun 项目及其多个独立实例。

Nginx 继续负责域名、HTTPS、反向代理和负载均衡。

```text
Internet
  ↓
Nginx
  ├── api.example.com
  ├── upload.example.com
  └── other.example.com
  ↓
bm2 管理的 Bun 实例
  ├── api-0      127.0.0.1:3000
  ├── api-1      127.0.0.1:3001
  ├── api-2      127.0.0.1:3002
  ├── api-3      127.0.0.1:3003
  ├── upload-0   127.0.0.1:3100
  └── upload-1   127.0.0.1:3101
```

`bm2` 由 MoonBit 编译为 Linux 原生可执行文件。

被管理的业务进程始终通过 Bun 启动。

```text
bm2d
  ├── bun index.ts
  ├── bun index.ts
  └── bun index.ts
```

## 设计目标

### 必须支持

- 仅管理 Bun 项目。
- 仅支持 Linux。
- 在本机 WSL 的 Debian 环境完成 native 构建与验证。
- 管理多个项目。
- 每个项目支持多个实例。
- 启动命令固定为 `bun <script>`。
- 崩溃自动重启。
- 配置最大连续重启次数。
- 配置实例最大内存。
- 每个实例使用独立端口。
- 每个项目和实例使用独立工作目录、PID、状态与日志。
- 支持 `start`、`stop`、`kill`、`status` 命令。
- `start` 对目标范围执行完全重启。
- 记录运行日志、错误日志和崩溃诊断日志，直接查看日志文件。
- 使用静态 TOML 配置，不执行 JavaScript 配置。
- 配置解析使用纯 MoonBit TOML 库。
- bm2 源码全部使用 MoonBit，Linux 系统能力通过最小 POSIX FFI 提供。
- MoonBit 项目使用 `moon.mod` 与各包目录的 `moon.pkg`，不使用已弃用的 JSON 清单。

### 明确不做

- 不管理 Node.js、Python、Go、Java 或任意其他运行时。
- 不支持 Windows 和 macOS，也不为跨平台预留抽象层。
- 不支持 watch 文件与热重载。
- 不支持开机自启。
- 不提供 HTTP、RPC、WebSocket 或 Web 管理接口。
- 不管理域名、证书、DNS 或 Nginx 配置。
- 不实现 HTTP 反向代理。
- 不实现日志轮转、指标监控、告警系统和远程管理。
- 不实现 Node.js `cluster` 语义。
- 不提供 `logs` 和 `restart` 命令。
- 不执行用户在配置中提供的 shell 命令字符串。
- 不在配置或日志中保存业务密钥。

## 为什么不实现 PM2 的 cluster 模式

PM2 的 `cluster` 模式主要服务于 Node.js 的 `cluster` 运行时能力。

Node 的主进程和 worker 可以共享一个监听端口，并由运行时协调连接分发。

Bun 没有可由外部进程管理器通用开启的等价 cluster CLI 能力。

即使 bm2 启动四个 Bun 进程，它们也不能同时绑定同一个端口。

```text
api-0 → 127.0.0.1:3000  成功
api-1 → 127.0.0.1:3000  端口占用
```

要让所有实例使用同一端口，只能额外实现网络层能力。

例如通过 `SO_REUSEPORT` 改造每个业务项目，或者让 bm2 自己成为 HTTP/TCP 代理。

前者不通用，后者会让 bm2 从进程管理器膨胀为代理服务器。

这两种方式都不适合作为第一版的基础能力。

因此 bm2 采用更直接的 `fork` 多实例方案。

```text
api
├── api-0 → PORT=3000
├── api-1 → PORT=3001
├── api-2 → PORT=3002
└── api-3 → PORT=3003
```

Nginx 的 upstream 负责把请求轮询分发到这些实例。

这套结构和 PM2 的目标一致：利用多核、单实例故障隔离、崩溃自动恢复。

区别只是请求分发从 Node runtime 内部转移到更成熟的 Nginx。

## 整体架构

bm2 分为 CLI 和守护进程两部分。

```text
bm2 CLI
  ↓ Unix Domain Socket
bm2d 守护进程
  ├── TOML 配置读取与校验
  ├── 项目 dotenv 环境隔离
  ├── 服务状态维护
  ├── Bun 子进程创建与回收
  ├── 崩溃重启策略
  ├── 内存巡检
  ├── 日志与诊断
  └── PID 和状态持久化
```

### bm2 CLI

`bm2` 是用户直接使用的命令行程序。

它不直接管理业务进程。

它负责解析命令，将请求发送给常驻的 `bm2d`，接收结果后输出到终端。

例如：

```bash
bm2 start
bm2 stop api
bm2 kill api
bm2 status
```

### bm2d 守护进程

`bm2d` 是真正维护业务进程的父进程。

它必须持续运行，才能监听子进程退出、监控内存并执行自动重启。

`bm2 start` 的行为如下：

1. 读取并校验 `bm2.toml`。
2. 检查本地 Unix Domain Socket 是否已有可用 `bm2d`。
3. 没有守护进程时，启动一个脱离当前终端的 `bm2d`。
4. 将目标范围的完全重启请求发送给 `bm2d`。
5. `bm2d` 确认目标旧实例全部退出后，再按当前配置创建实例。
6. CLI 等待操作结果并输出状态。

Unix Domain Socket 只位于本机状态目录内。

它不是外部接口，也不绑定 TCP 端口。

建议默认路径：

```text
~/.local/state/bm2/bm2.sock
```

可通过配置覆盖状态根目录。

## bm2 的目录结构

仓库根目录就是一个独立的 MoonBit 模块。

当前只有这一个模块，因此不创建 `moon.work`。

```text
bm2/
├── moon.mod
├── moon.pkg
├── README.mbt.md
├── src/
│   ├── config/
│   │   ├── moon.pkg
│   │   ├── model.mbt
│   │   ├── parse.mbt
│   │   └── validate.mbt
│   ├── core/
│   │   ├── moon.pkg
│   │   ├── app.mbt
│   │   ├── instance.mbt
│   │   ├── supervisor.mbt
│   │   ├── state.mbt
│   │   └── protocol.mbt
│   ├── process/
│   │   ├── moon.pkg
│   │   ├── spawn.mbt
│   │   ├── wait.mbt
│   │   ├── signal.mbt
│   │   ├── procfs.mbt
│   │   ├── socket.mbt
│   │   └── native.c
│   ├── cmd/
│   │   ├── bm2/
│   │   │   ├── moon.pkg
│   │   │   └── main.mbt
│   │   └── bm2d/
│   │       ├── moon.pkg
│   │       └── main.mbt
│   └── testkit/
│       ├── moon.pkg
│       └── fixtures.mbt
└── tests/
```

`moon.mod` 定义模块名称、依赖与 native 目标。

`moon.pkg` 放在每个包目录内；可执行包使用：

```moonbit
pkgtype(kind: "executable")
```

根目录的 `moon.pkg` 只在需要组织根包时使用。

MoonBit 用于 CLI、配置模型、状态机、调度逻辑、日志组织和测试。

Linux 系统能力集中在 `process` 包，通过最小 POSIX FFI 提供。

```text
fork
execve
waitpid
kill
setsid
setpgid
chdir
pipe
open
close
dup2
read
write
unlink
socket
bind
listen
accept
connect
```

如果 MoonBit 标准库已提供某项 Unix 能力，应优先使用标准库。

只有标准库缺失时才补充 FFI。

## 配置文件

MoonBit 不应执行 JavaScript 配置。

第一版使用静态 TOML 文件，默认配置文件名为 `bm2.toml`。

TOML 解析使用纯 MoonBit 依赖，不引入 C TOML 库。

候选依赖在实现前必须先在本机 WSL Debian 中以 native 目标验证；验证不通过时停止，不切换到 YAML，也不自行实现不完整解析器。

```toml
state_dir = "~/.local/state/bm2"

[[apps]]
name = "api"
cwd = "/srv/yicode/api"
script = "index.ts"
instances = 4
port = 3000
max_memory_mb = 512
max_restarts = 10
restart_delay_ms = 1000
min_uptime_ms = 10000
stop_timeout_ms = 10000

[[apps]]
name = "upload"
cwd = "/srv/yicode/upload"
script = "index.ts"
instances = 2
port = 3100
max_memory_mb = 256
max_restarts = 5
restart_delay_ms = 1000
min_uptime_ms = 10000
stop_timeout_ms = 10000
```

### 全局字段

| 字段        | 类型   | 说明                                 |
| ----------- | ------ | ------------------------------------ |
| `state_dir` | string | bm2 的状态、PID、Socket 和日志根目录 |
| `apps`      | array  | 被管理的 Bun 服务列表                |

### app 字段

| 字段               | 类型    | 说明                                           |
| ------------------ | ------- | ---------------------------------------------- |
| `name`             | string  | 全局唯一的服务名，只允许小写字母、数字和连字符 |
| `cwd`              | string  | 启动 Bun 进程时使用的项目根目录                |
| `script`           | string  | 相对于 `cwd` 的 Bun 入口文件                   |
| `instances`        | integer | 实例数量，最小为 `1`                           |
| `port`        | integer | 第一个实例使用的本地端口                       |
| `max_memory_mb`    | integer | 单实例最大 RSS 内存，单位 MB                   |
| `max_restarts`     | integer | 单实例最大连续异常重启次数                     |
| `restart_delay_ms` | integer | 异常退出后的重启等待时间                       |
| `min_uptime_ms`    | integer | 实例稳定运行到该时间后，连续重启计数归零       |
| `stop_timeout_ms`  | integer | `SIGTERM` 后等待优雅退出的最长时间             |

第一版不提供配置级 `env` 表。

生产环境变量由项目目录内的 `.env` 文件管理，bm2 只负责以正确 `cwd` 启动实例并隔离最终进程环境。

### 端口规则

实例端口固定按以下公式生成：

```text
instancePort = port + instanceId
```

例如：

```text
api.instances = 4
api.port = 3000

api-0 → 3000
api-1 → 3001
api-2 → 3002
api-3 → 3003
```

bm2 在启动前计算所有端口范围。

配置校验必须拒绝端口范围重叠。

```text
api     3000 ~ 3003
upload  3002 ~ 3003

结果：拒绝启动
原因：api 与 upload 的端口范围重叠
```

bm2 只分配并注入端口。

业务 Bun 服务必须读取 `PORT` 实际监听该端口。

## 环境变量隔离

环境变量隔离是 bm2 的硬性能力。

每次创建实例时，bm2 必须构造全新的 `envp`，再通过 `execve` 传给 Bun。

不能直接修改 bm2d 自身的进程环境，也不能复用另一个 app 的环境对象。

bm2 负责的基础环境由以下数据组成：

```text
最小系统环境
+ bm2 保留变量
```

每个实例以自己的 `cwd` 启动，Bun 随后按本地规则自动读取该项目的 `.env` 文件。

`NODE_ENV` 可通过最小系统环境或项目 `.env` 提供给 Bun；bm2 不解析 dotenv 文件内容。

实例专属变量固定为：

```text
BM2_APP_NAME=<app name>
BM2_INSTANCE_ID=<instance id>
PORT=<port + instanceId>
```

这三个名称是保留变量，由 bm2 在进程环境中显式注入。

Bun 的进程环境优先级高于其自动读取的 `.env` 文件，因此项目 dotenv 不能覆盖保留变量。

bm2 不使用 `--no-env-file`，默认保留 Bun 对本地 `.env` 文件的自动加载行为。

例如：

```text
api-0
BM2_APP_NAME=api
BM2_INSTANCE_ID=0
PORT=3000
RUN_MODE=production

upload-0
BM2_APP_NAME=upload
BM2_INSTANCE_ID=0
PORT=3100
RUN_MODE=production
```

这样不同项目不会共享同一个 `env` 对象，也不会出现配置串用问题。

### `.env` 文件规则

每个 Bun 实例都以 app 的 `cwd` 作为当前目录启动。

因此项目自身的 `.env` 文件只属于该项目目录。

bm2 不读取、不合并、不写入其他项目的 `.env` 文件。

为了保证运行环境可预测，第一版采用以下规则：

- bm2 配置不提供通用 `env` 表。
- 每个项目的 `.env` 只允许作为该项目内部默认配置。
- bm2 启动前不得继承调用 `bm2` 命令的全部 shell 环境。
- 只保留 Bun 正常运行需要的最小系统变量，例如 `PATH`、`HOME`、`TMPDIR`。
- Bun 在每个项目的 `cwd` 内自动读取 `.env`、`.env.{NODE_ENV}`、`.env.local`。
- 集成测试必须验证 `api` 的变量不会出现在 `upload` 进程中。
- 集成测试必须验证 `.env` 不能覆盖 `PORT`、`BM2_APP_NAME` 和 `BM2_INSTANCE_ID`。
- 状态文件和日志只记录环境来源与冲突，不记录环境变量值。

## Bun 进程启动模型

每个实例都是独立的 Linux 子进程。

入口文件模式启动命令固定为：

```text
bun <script>
```

例如：

```text
bun index.ts
```

`script` 必须解析为 `cwd` 下的真实文件路径，不接受 shell 字符串、管道、重定向或参数拼接。

第一版不支持 package script 名称。

如果后续需要支持 package script，必须使用单独的 `script_kind` 配置，并固定为 `bun run <name>`；不能和入口文件共用同一个字段语义。

不支持配置 Node、Python、shell 或其他解释器。

### 启动步骤

以 `api-2` 为例：

```text
bm2d
  ↓
fork
  ↓
child process
  ├── setsid 或 setpgid，建立独立进程组
  ├── chdir(/srv/yicode/api)
  ├── 重定向 stdout 到 api-2.out.log
  ├── 重定向 stderr 到 api-2.error.log
  ├── 构造 api-2 专属 envp
  └── execve(bun, [bun, index.ts], envp)
```

父进程保留以下运行信息：

```text
appName
instanceId
pid
pgid
port
startedAt
restartCount
status
lastExitCode
lastSignal
lastReason
```

### 为什么要维护进程组

业务 Bun 进程可能继续启动子进程。

只向主 PID 发送 `SIGTERM`，可能造成子进程残留。

因此 bm2 应将每个实例放入独立进程组，并通过负 PID 向整个进程组发送信号。

```text
kill(-pgid, SIGTERM)
```

这能让 `start` 的完全重启、`stop`、`kill` 清理整个实例树。

## 守护与状态机

每个实例都有独立状态。

```text
stopped
  ↓ start
starting
  ↓ exec 成功
online
  ↓ 异常退出或内存超限
restarting
  ↓ 超过 max_restarts
errored
  ↓ start
stopping
  ↓ 旧实例退出完成
starting
  ↓ exec 成功
online
```

### 正常退出

业务服务主动以 `0` 退出时，bm2 视为正常结束。

如果该退出由 `stop` 或 `start` 的完全重启发起，实例进入 `stopped` 或等待重新启动。

如果服务没有被 bm2 请求停止却自行正常退出，第一版仍记录退出并按重启策略拉起，避免常驻服务意外消失。

### 异常退出

以下情况视为异常退出：

- 非 `0` 退出码。
- 收到崩溃信号。
- 启动后在 `min_uptime_ms` 内退出。
- RSS 内存超过 `max_memory_mb` 被 bm2 终止。
- `execve` 启动 Bun 或入口文件失败。

异常处理流程：

```text
实例退出
  ↓
写 crash.log
  ↓
restartCount + 1
  ↓
restartCount > max_restarts
  ├── 是：状态改为 errored，停止自动重启
  └── 否：等待 restart_delay_ms 后创建新实例
```

### 连续重启次数

`max_restarts` 应定义为连续异常重启次数。

实例连续稳定运行超过 `min_uptime_ms` 后，重启计数归零。

例如：

```text
max_restarts = 3
min_uptime_ms = 10000

第 1 次崩溃，重启计数为 1
第 2 次崩溃，重启计数为 2
稳定运行 12 秒，重启计数归零
后续崩溃，重启计数重新从 1 开始
```

这个规则避免偶发故障在长时间后永久耗尽重启额度。

## 内存限制

Bun 的子进程资源统计只能在进程退出后获得峰值数据。

它不能用于运行中内存上限控制。

bm2 必须通过 Linux procfs 读取实时 RSS 内存。

读取路径：

```text
/proc/<pid>/status
```

读取字段：

```text
VmRSS: 123456 kB
```

bm2 每隔固定时间巡检全部 `online` 实例。

第一版默认间隔建议为 `5000ms`。

### 内存超限流程

```text
VmRSS > max_memory_mb
  ↓
写入 crash.log
  ↓
记录 reason = memory_limit
  ↓
向实例进程组发送 SIGTERM
  ↓
等待 stop_timeout_ms
  ↓
仍未退出时发送 SIGKILL
  ↓
由统一异常重启策略决定是否拉起新实例
```

最大内存按单实例计算。

例如：

```text
instances = 4
max_memory_mb = 512

总理论 RSS 上限约为 2048 MB
```

bm2 第一版不实现系统总内存配额，也不实现 cgroup。

`max_memory_mb` 是应用级的守护限制，不是 Linux 内核级硬内存限制。

## 状态、PID 与日志目录

状态根目录由 `state_dir` 指定。

默认状态目录按 Linux 用户状态目录解析：

```text
$XDG_STATE_HOME/bm2
```

`XDG_STATE_HOME` 未设置时使用：

```text
~/.local/state/bm2
```

系统级部署可显式配置 `/var/lib/bm2`。

建议目录结构：

```text
~/.local/state/bm2/
├── bm2.sock
├── bm2d.pid
├── apps.json
├── api/
│   ├── api-0.json
│   ├── api-1.json
│   ├── api-2.json
│   ├── api-3.json
│   └── logs/
│       ├── api-0.out.log
│       ├── api-0.error.log
│       ├── api-0.crash.log
│       ├── api-1.out.log
│       └── ...
└── upload/
    ├── upload-0.json
    └── logs/
```

### 单实例状态文件

`api/api-0.json` 示例：

```json
{
  "appName": "api",
  "instanceId": 0,
  "pid": 18234,
  "pgid": 18234,
  "port": 3000,
  "status": "online",
  "startedAt": "2026-07-30T10:20:30.000Z",
  "restartCount": 0,
  "lastExitCode": null,
  "lastSignal": null,
  "lastReason": null
}
```

状态文件采用 JSON 是因为它由 bm2 机器生成，不属于用户维护的配置文件。

状态文件必须采用原子写入。

推荐流程：

```text
写入临时文件
  ↓
fsync
  ↓
rename 覆盖正式状态文件
```

这样 bm2d 非正常退出时，不会留下半截 JSON。

### 日志分类

每个实例至少有三类日志：

| 文件                   | 内容                     |
| ---------------------- | ------------------------ |
| `<app>-<id>.out.log`   | 子进程 stdout            |
| `<app>-<id>.error.log` | 子进程 stderr            |
| `<app>-<id>.crash.log` | bm2 写入的崩溃与重启诊断 |

崩溃日志示例：

```text
2026-07-30T10:20:31.000Z app=api instance=2 pid=18236
reason=memory_limit
rssMb=529
limitMb=512
signal=SIGTERM
restartCount=3
```

stdout 和 stderr 必须持续追加写入。

第一版不做日志轮转。

日志轮转是后续独立能力，不应混入进程守护核心。

## CLI 命令

### start

```bash
bm2 start
bm2 start api
```

行为：

- 没有 app 参数时，按配置完全重启所有服务。
- 指定 app 时，只完全重启目标服务的全部实例。
- 先向目标实例进程组发送 `SIGTERM`。
- 等待 `stop_timeout_ms` 后仍未退出时发送 `SIGKILL`。
- 必须等旧实例全部退出，再按当前配置启动新实例。
- 首次启动时没有旧实例，因此不发送停止信号，直接启动。
- 完全重启会清零目标实例的连续重启计数。
- 同一目标上已有 `start` 操作时，新的 `start` 必须拒绝并报告操作冲突。

### stop

```bash
bm2 stop
bm2 stop api
```

行为：

- 向目标服务的全部实例进程组发送 `SIGTERM`。
- 等待 `stop_timeout_ms`。
- 超时后发送 `SIGKILL`。
- 被显式停止的实例不得自动重启。
- 更新状态为 `stopped`。

### kill

```bash
bm2 kill
bm2 kill api
```

行为：

- 立即向目标实例进程组发送 `SIGKILL`。
- 标记为人为强制终止。
- 不自动重启。
- 需要后续显式 `start` 恢复。

### status

```bash
bm2 status
bm2 status api
```

输出建议：

```text
name    id  pid    port  status   restarts  memory  uptime
api     0   18234  3000  online   0         78 MB   2h 11m
api     1   18235  3001  online   1         81 MB   1h 09m
api     2   -      3002  errored  10        -       -
upload  0   18310  3100  online   0         43 MB   4h 20m
```

### 查看日志

第一版不提供 `logs` 命令。

根据 `status` 输出的 app 与实例编号，直接查看状态目录下的日志文件。

```bash
tail -f ~/.local/state/bm2/api/logs/api-0.out.log
tail -f ~/.local/state/bm2/api/logs/api-0.error.log
tail -f ~/.local/state/bm2/api/logs/api-0.crash.log
```

## Nginx 配置边界

Nginx 不由 bm2 生成或修改。

部署人员根据 bm2 配置中固定的 `port` 与 `instances` 手动维护 Nginx upstream。

API 的 Nginx 示例：

```nginx
upstream yicode_api {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
    server 127.0.0.1:3003;
}

server {
    listen 443 ssl http2;
    server_name api.example.com;

    location / {
        proxy_pass http://yicode_api;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

上传服务的 Nginx 示例：

```nginx
upstream yicode_upload {
    server 127.0.0.1:3100;
    server 127.0.0.1:3101;
}

server {
    listen 443 ssl http2;
    server_name upload.example.com;

    location / {
        proxy_pass http://yicode_upload;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Nginx 与 bm2 的职责必须保持分离。

```text
Nginx 负责网络流量。
bm2 负责进程生命周期。
Bun 项目负责业务逻辑。
```

## 故障处理边界

### bm2d 启动时发现旧 PID

状态文件可能存在，但 PID 已退出。

bm2d 启动时必须验证 PID：

```text
kill(pid, 0)
```

结果如下：

- PID 存活且命令信息匹配，恢复为受管实例。
- PID 不存在，删除陈旧状态并按配置启动新实例。
- PID 存在但不属于 bm2 记录的 Bun 实例，停止并报告状态冲突，不得误杀。

### 端口已被占用

子进程能够启动但业务服务绑定端口失败时，通常会立即退出并写入 stderr。

bm2 记录该退出为启动失败，并受 `max_restarts` 限制。

bm2 不主动抢占或终止占用端口的未知进程。

### 守护进程异常退出

第一版不支持系统级开机自启，也不承诺 bm2d 自己崩溃后的自动恢复。

当 bm2d 正常退出或被显式终止时，它应向全部受管进程组发送 `SIGTERM`。

如果 bm2d 因 `SIGKILL`、系统崩溃或自身严重错误退出，Linux 无法保证清理已完成。

下一次 `bm2 start` 必须验证状态文件中的 PID，发现受管残留实例时先执行完全重启的清理步骤，再重新启动。

这比让业务进程继续运行但无人监控更可预测。

### Nginx upstream 与实例数量不一致

bm2 不修改 Nginx，所以实例数量调整后需要人工同步 upstream。

例如将 `api.instances` 从 `4` 改为 `2`，必须同步移除 `3002`、`3003`。

第一版只在 `status` 输出端口列表。

后续可增加只读命令：

```bash
bm2 status api --nginx-upstream
```

它只打印可复制的 upstream server 行，不写入 Nginx 文件。

## 安全边界

bm2 在 Linux 上拥有启动和终止进程的能力。

它必须限制配置与状态目录的权限。

建议：

```text
state_dir 权限：0700
bm2.sock 权限：0600
日志文件权限：0600
```

bm2 不接受网络请求，只接受本机 Unix Socket 客户端。

Socket 服务端必须验证同一 Unix 用户身份。

bm2 不执行用户在配置中提供的 shell 字符串。

启动命令固定为参数数组：

```text
[bunPath, scriptPath]
```

禁止：

```text
sh -c <用户输入>
```

这样可避免配置值被当作 shell 代码执行。

环境变量值不得写入状态文件、crash 日志或 CLI 输出。

## 分阶段实施计划

### 工具链与依赖门槛

目标：在本机 WSL Debian 中固定实现前环境。

内容：

- 在 WSL Debian 中安装 MoonBit 与 Bun。
- 锁定并记录 `moon --version`、`moonc --version` 和 `bun --version`。
- 创建 `moon.mod` 和包级 `moon.pkg`。
- 引入纯 MoonBit TOML 依赖。
- 使用 native 目标构建最小 TOML 解析 fixture。
- 验证 TOML 依赖在当前 native 工具链下可用。

验证：

```text
moon fmt --check
moon check --target native --deny-warn
moon test --target native
```

验证失败时立即停止，不切换到 YAML、不自写 TOML 子集、不继续使用 JSON。

### 基础包和配置

目标：建立可独立构建的 MoonBit 包，并完成 TOML 配置模型。

内容：

- 实现 `bm2.toml` 读取与字段校验。
- 实现 app 名称、路径、实例数、端口范围、内存、重启次数校验。
- 实现配置中端口范围重叠检测。
- 增加配置单元测试。

验证：

```text
合法配置可解析。
端口重叠、重复名称、缺失脚本等非法配置被拒绝。
解析错误包含字段路径与位置。
```

### dotenv 与环境隔离

目标：固定项目 `.env` 自动加载与实例环境构造规则。

内容：

- 实现最小系统环境白名单。
- 实现保留变量写入与 `.env` 冲突检测。
- 实现每个实例独立 `envp`。
- 验证 Bun 在各项目 `cwd` 下自动读取 dotenv。
- 增加跨 app 环境隔离测试。

验证：

```text
api 变量不出现在 upload 实例中。
.env 不能覆盖 PORT、BM2_APP_NAME、BM2_INSTANCE_ID。
最终 envp 不包含调用 bm2 的完整 shell 环境。
```

### Linux 进程封装

目标：以最小 POSIX FFI 启动并终止一个 Bun 进程。

内容：

- 实现 `fork`、`chdir`、`execve`、`waitpid`。
- 实现 stdout 和 stderr 文件重定向。
- 实现独立进程组。
- 实现 `SIGTERM` 和 `SIGKILL`。
- 实现最小 PID 状态文件。

验证：

```text
启动 fixture Bun 服务。
确认 cwd、PORT、BM2_INSTANCE_ID 和 dotenv 环境正确。
stop 后确认进程组内所有进程退出。
```

### 守护、崩溃重启和日志

目标：实现单 app、多实例的持续守护。

内容：

- 实现实例状态机。
- 监听 `waitpid` 结果。
- 实现 `restart_delay_ms`、`min_uptime_ms`、`max_restarts`。
- 实现运行、错误和崩溃日志。
- 实现状态原子写入。

验证：

```text
fixture 主动非零退出后自动重启。
连续崩溃超过 max_restarts 后状态为 errored。
稳定运行超过 min_uptime_ms 后重启计数归零。
```

### 内存监控

目标：对运行中的每个实例实施独立 RSS 内存限制。

内容：

- 解析 `/proc/<pid>/status` 的 `VmRSS`。
- 建立固定时间间隔的巡检任务。
- 超限后完成记录、SIGTERM、超时 SIGKILL 与自动恢复。

验证：

```text
fixture 持续分配内存。
超过 max_memory_mb 后被终止。
crash.log 含 memory_limit、RSS 和阈值。
未超过最大次数时新实例成功拉起。
```

### CLI 与 Unix Socket

目标：将 CLI 和常驻守护进程连接起来。

内容：

- 实现 `bm2d` Unix Domain Socket 服务端。
- 实现 `start`、`stop`、`kill`、`status` 客户端命令。
- 设计并实现长度前缀 JSON 请求和响应协议。
- 拒绝非法命令、未知 app 和并发冲突操作。

验证：

```text
并发执行两次 start 只保留一个有效操作。
start 会等待旧实例退出再启动新实例。
status 能显示 PID、端口、内存、重启次数和运行时长。
```

### 文档与发布准备

目标：让 bm2 可作为 Linux 独立包发布和部署。

内容：

- 编写 README。
- 说明 Linux、Bun 和 Nginx 前置条件。
- 提供 `bm2.toml` 与 Nginx upstream 完整示例。
- 说明状态目录权限、日志目录和手动部署步骤。
- 说明 WSL Debian 只用于开发验证，不代表系统级生产部署方式。
- 配置独立发布元数据。

验证：

```text
在本机 WSL Debian 构建 bm2。
使用两个 fixture Bun 项目启动多个实例。
通过 Nginx upstream 访问多个实例。
单实例崩溃、内存超限和 CLI 启停均通过验证。
```

## 最小验收标准

第一版完成时，必须满足以下标准：

1. 一个 `bm2.toml` 可以配置至少两个 Bun 项目。
2. 每个项目可配置至少两个实例。
3. 每个实例获得独立 `PORT`、`BM2_APP_NAME`、`BM2_INSTANCE_ID`。
4. Bun 在每个实例自己的 `cwd` 下自动读取 `.env`、`.env.{NODE_ENV}`、`.env.local`。
5. 不同 app 的环境变量不串用，`.env` 不能覆盖保留变量。
6. 实例 stdout、stderr 与 crash 日志独立保存。
7. 业务崩溃后按配置延迟重启。
8. 超过连续重启次数后状态为 `errored`。
9. RSS 超过单实例内存上限时被终止并按重启策略处理。
10. `start`、`stop`、`kill`、`status` 可用。
11. `start` 无旧实例时直接启动，有旧实例时先清理旧实例树再启动。
12. `stop` 和 `kill` 不遗留实例的子进程。
13. Nginx 可以通过 upstream 将流量分发给 bm2 管理的多个本地端口。
14. bm2 不修改 Nginx 文件，不监听外网端口，不提供外部接口。
15. 所有 MoonBit 构建、检查与 native 测试都在本机 WSL Debian 通过。

## 最终结论

bm2 的第一版应定位为：

> 一个使用 MoonBit 编写、只面向 Linux Bun 项目的轻量进程守护器。

它通过 `fork + exec` 启动多个独立 Bun 实例。

它通过 PID、进程组、`waitpid`、`/proc` 和日志文件完成生命周期维护。

它使用连续本地端口承载多实例。

它使用 TOML 管理静态配置，通过 Bun 默认加载项目 `.env` 管理业务环境，并使用 bm2 保留变量承载实例运行时信息。

Nginx 独立负责公网流量、HTTPS 与负载均衡。

这种分工比在 bm2 内部实现 HTTP 代理或强行模拟 Node cluster 更简单、稳定和可维护。
