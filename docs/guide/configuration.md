# 配置参考

一份 `bm2.toml` 描述**一个项目**：单个应用，配一个或多个实例。

放在项目目录里，在该目录执行 `bm2 serve` 或 `bm2 dev`。

配置里的任何内容都不会被执行。没有 shell 字符串，没有脚本钩子，没有表达式语言——每个值都是数据。bm2 不认识的字段会直接报错，而不是被悄悄忽略。

不连守护进程也能校验：

```bash
bm2 check
```

`serve` / `dev` 在登记之前跑同一套校验，所以非法配置到不了被托管的进程那里。

## 最小可用配置

```toml
name = "api"
script = "src/index.ts"
instances = 2
port = 3000
```

四个必填字段，其余全有默认值。

## 完整模板

```toml
# 项目名。字母开头，后接字母、数字和下划线。在所有已注册项目中唯一。
name = "api"

# 应用工作目录，绝对路径。默认是 bm2.toml 所在目录。
cwd = "/srv/api"

# 相对 cwd 的脚本路径，禁止 .. 段。
script = "src/index.ts"

# 运行时：bun 或 node。
runtime = "bun"

# 执行模式：cluster（默认，共享端口）或 fork（端口连续分配）。
exec_mode = "cluster"

# 实例数量，1 到 1024。开发模式恒为 1。
instances = 2

# 起始端口。cluster 只用这一个。fork 从这里连续分配。
port = 3000

# 单实例内存上限（MiB），超过按异常重启处理。
max_memory_mb = 512

# 连续异常重启预算。0 表示首次异常就进入 errored。
max_restarts = 10

# 异常退出后到重启之间的延迟（毫秒）。spawn 失败时按次数递增。
restart_delay_ms = 1000

# 短于此运行时长（毫秒）的干净退出也计入重启预算。
min_uptime_ms = 10000

# SIGTERM 到 SIGKILL 的宽限期（毫秒），1 到 60000。
stop_timeout_ms = 10000

# 项目文案语言：en 或 zh。省略则跟随操作者。
lang = "zh"

# 日志轮转。不写这张表就是 10 MiB、代数不限。
[logs]
max_size_mb = 10
keep = 0

# 通知。不写这一段就是完全不上报。
[notify]
enabled = false
```

## 字段总表

| 字段 | 必填 | 默认 | 约束 | 说明 |
| --- | --- | --- | --- | --- |
| `name` | 是 | — | 字母开头，后接字母、数字、下划线 | 项目名：状态目录下的目录名，也是 `bm2 <命令> <name>` 认的名字 |
| `cwd` | 否 | 配置文件所在目录 | 绝对路径，必须以 `/` 开头 | 应用的**工作目录**，`script` 与它自己的 `.env` 都相对它解析 |
| `script` | 是 | — | 相对路径，非空，不得是绝对路径，不得含 `..` 段 | 入口文件，相对 `cwd`；启动命令就是 `<runtime> <script>`，没有参数位 |
| `runtime` | 否 | `bun` | `bun` 或 `node` | 用什么运行时拉起应用，按 `PATH` 解析 |
| `exec_mode` | 否 | `cluster` | `cluster` 或 `fork` | `cluster` 让多实例共享一个端口（靠内核 `SO_REUSEPORT`），`fork` 是普通多实例 |
| `instances` | 是 | — | `1 ~ 1024` | 实例数；`cluster` 下它们平分 `port` 起的端口段 |
| `port` | 是 | — | `1 ~ 65535`，且 `port + instances - 1 <= 65535` | 起始端口，从它往后每个实例占一个 |
| `max_memory_mb` | 否 | `512` | `1 ~ 1048576` | 单实例内存上限，超了按异常重启处理，并触发内存类事件 |
| `max_tree_processes` | 否 | `512` | `1 ~ 65536` | 统计内存时最多走多少个后代进程，防止病态进程树拖慢采样 |
| `max_restarts` | 否 | `10` | `0 ~ 2147483647` | 重启预算：用完就停手并报 `errored`；`0` 表示首次异常即停 |
| `restart_delay_ms` | 否 | `1000` | `0 ~ 2147483647` | 异常退出后等多久再拉起，避免崩溃循环打满 CPU |
| `min_uptime_ms` | 否 | `10000` | `0 ~ 2147483647` | 活够这么久才算「跑起来了」；不到就算一次失败重启，不进预算白名单 |
| `stop_timeout_ms` | 否 | `10000` | `1 ~ 60000` | 停机时给应用的优雅退出时间，超时升级成 `SIGKILL` |
| `lang` | 否 | 跟随操作者 | `en` 或 `zh` | 这个项目的输出语言，通知也默认跟它走 |
| `[logs] max_size_mb` | 否 | `10` | `1 ~ 102400` | 单个日志文件超过它就轮转 |
| `[logs] keep` | 否 | `0` | `0 ~ 1000` | 轮转后保留几代，`0` 表示代数不限 |
| `[notify]` | 否 | 关闭 | 见[通知](/guide/notifications) | 事件告警与每日统计，字段见下方子表索引 |

`name` 同时是状态目录下的目录名，所以字符集收得很紧，只允许路径里安全的字符。

`port` 的上限检查先做单值检查、再做范围检查，所以 `port = 2147483647` 这类值不会被加法绕过去。

## 子表字段索引

两张子表的字段不在这张表里展开：默认值与取值范围只写在各自的正文页，这里只做索引，保证从配置页出发不会漏掉任何一个键。

### `[logs]`

| 字段 | 说明 | 详见 |
| --- | --- | --- |
| `max_size_mb` | 单个日志文件的轮转阈值 | [状态与日志](/guide/state-and-logs) |
| `keep` | 轮转后保留的代数，`0` 为不限 | [状态与日志](/guide/state-and-logs) |

### `[notify]`

| 字段 | 说明 |
| --- | --- |
| `enabled` | 通知总开关，默认关闭 |
| `lang` | 发出去的消息用什么语言，默认跟随项目 `lang` |
| `timeout_ms` | 单个目标的投递硬超时 |
| `dedupe_window_s` | 同一告警在这个窗口内只说一次，重复只计数 |
| `max_per_minute` | 每分钟即时上报上限，按项目计 |
| `queue_size` | 待投递队列深度，满了丢最新的 |
| `daily_report_hour` | 每日统计在本地时间几点发 |
| `threshold_rss_percent` | 内存占 `max_memory_mb` 的百分比，到了就报 |
| `threshold_offline_min` | 实例非 online 持续多久就报 |
| `threshold_restarts` | 连续异常重启多少次就报 |
| `start_timeout_ms` | 拉起后端口多久还没监听就算启动超时 |
| `threshold_disk_mb` | 状态盘剩余空间低于多少就报 |
| `threshold_storm` | 十分钟窗口内重启次数上限，超了报重启风暴 |
| `mail_url` | SMTP 地址，所有邮件目标共用这一条通道 |
| `mail_from` | 发件人地址，用邮件目标时必填 |
| `mail_username` | 中继需要认证时的用户名 |
| `mail_password` | 中继需要认证时的密码 |

字段的默认值、取值范围与关闭方式见[通知](/guide/notifications)。

### `[[notify.target]]`

| 字段 | 说明 |
| --- | --- |
| `platform` | 投递平台，七选一：feishu / dingtalk / wecom / slack / discord / webhook / email |
| `url` | 网页平台的地址，`http://` 或 `https://` 开头；邮件目标不写 |
| `to` | 邮件收件人数组；网页平台不写 |
| `secret` | 加签密钥或 Bearer 令牌，含义按平台不同 |
| `format` | 报文形状：text / markdown / card |
| `events` | 这个目标收哪些事件：不写=全部，列出来=白名单，`!` 前缀=排除 |

写法与示例见[通知](/guide/notifications)。

## 启动命令怎么拼

被托管的进程就是一条命令：`<runtime> <script>`。

```text
bun src/index.ts
node dist/server.js
```

- `runtime` 走 `PATH` 解析，不写绝对路径。
- `script` 作为**一个**参数传进去，不做 shell 分词，也不展开 `~` 或通配符。
- 没有参数位：`bm2.toml` 里不能给应用传命令行参数。需要参数时，让应用读环境变量。
- 工作目录是 `cwd`，脚本路径相对它。
- 应用的 stdin 是 `/dev/null`，stdout 与 stderr 分别接两份日志文件。

## 一条配置一个项目

文件名固定是 `bm2.toml`，不能改名：`serve`、`dev`、`check`、`notify` 只读当前目录的这一份。

`bm2.toml` 里没有「项目列表」。一个文件就是一个项目，一个项目一个名字。

`.env` 系列始终在 `bm2.toml` 旁边，不在 `cwd`。把配置放在别处、`cwd` 指向应用目录时，环境文件仍然跟着配置走。

名字在全部已注册项目中唯一。同一个名字被**另一份**配置文件占用时拒绝登记，并报出占用者的路径。

```text
app api is already registered by /srv/other-api/bm2.toml; rename the project in bm2.toml, or retire the other one first
```

同一个文件通过符号链接、相对路径或 `..` 再次指向时不算「另一份」——登记前会做一次 `realpath`，比的是真实路径。

## 类型与占位符

字段类型是固定的：字符串字段只接受字符串，整数字段只接受整数。

一个例外专为占位符留出：**整数字段接受一个「全部是数字」的字符串**。因为 `__NAME__` 展开只发生在字符串上，`port = "__APP_PORT__"` 展开后就是一个字符串 `"3000"`，它必须能当整数用。字符串里出现空格、负号、小数点或任何非数字字符都会被拒绝，并点名该字段。

```toml
port = "__APP_PORT__"          # APP_PORT=3000 → 3000
max_memory_mb = "__MEM_MB__"   # 同理
```

布尔字段同理：`[notify] enabled` 接受 `true` / `false` 以及字符串 `"true"` / `"false"`。

`__NAME__` 占位符的完整规则写在[环境变量](/guide/environment)，包括查找顺序与未设置时的行为。

## 未知字段即报错

根级、`[logs]`、`[notify]`、`[[notify.target]]` 四层都做白名单校验。

```toml
name = "api"
script = "server.ts"
instances = 1
port = 3000
nope = 1
```

```text
InvalidField: root has unknown field nope
```

代价是配置不能夹带自定义注释性字段，收益是拼错字段名会立刻暴露——`instnaces` 写错时如果被忽略，你会以为改的是实例数。

`[env]` 表也是未知字段。环境变量只来自 `.env` 文件，详见[环境变量](/guide/environment)。

## 越界即拒绝，不猜

越界的值会让整份配置失败，不会被夹取、也不会被替换成默认值。

- `logs.max_size_mb = 0` 被拒绝，而不是理解成「永不轮转」。一个静默无限增长的日志，比让你写清大小更糟。
- `logs.keep` 为负被拒绝，因为 `0` 已经表示不限代数。
- `instances = 0` 被拒绝，不当作「按 CPU 核数自动决定」。
- `cwd` 给相对路径被拒绝。守护进程的工作目录与你 shell 的当前目录无关。

## 两个字段值得单独说

### `instances` 与开发模式

`instances` 是生产模式的实例数。`bm2 dev` 恒为 1，配置值在那里不生效。

这不是被悄悄丢掉：模式记在项目登记里，`bm2 list --json` 同时给出 `mode` 与实际实例数（行数）。

### `exec_mode` 与端口

`cluster` 让所有实例共用一个端口，`fork` 从 `port` 起连续分配。

端口范围冲突按模式算：cluster 项目占一个槽，fork 项目占 `instances` 个。两段有交集就拒绝登记。

两种模式对应用的要求不同，详见 [cluster 模式](/guide/mode-cluster) 与 [fork 模式](/guide/mode-fork)。

## 子表

| 子表 | 管什么 | 细节 |
| --- | --- | --- |
| `[logs]` | 应用日志的轮转大小与保留代数 | [状态与日志](/guide/state-and-logs) |
| `[notify]` | 事件上报、阈值、每日统计、目标与凭据 | [通知](/guide/notifications) |

两张子表都属于这个项目：日志是项目的日志，告警是项目的告警。一个项目不会替另一个项目上报。

## 重启策略速查

四个字段一起决定「崩了怎么办」，它们在[能力总览](/guide/features)里有行为层面的说明，这里只说取值含义。

| 字段 | 影响 |
| --- | --- |
| `restart_delay_ms` | 异常退出后固定延迟这么久再拉起。spawn 失败时按失败次数线性递增 |
| `max_restarts` | 连续异常重启的上限，超过即 `errored` 并停止自愈 |
| `min_uptime_ms` | 干净退出（退出码 0）短于这个时长，也算异常 |
| `stop_timeout_ms` | `SIGTERM` 之后等多久升级 `SIGKILL`，也是 CLI 等待上限的主要来源 |

「连续」的定义：只有「干净退出且活过 `min_uptime_ms`」才会把计数清零。所以一个每 15 分钟崩一次、`min_uptime_ms = 10000` 的进程仍然会累积预算，不会靠活得久洗掉自己的记录。

## 项目语言

`lang` 决定这个项目的文案用哪种语言：`bm2 list <name>` 的表头、针对它的状态提示、它自己的通知文案。

不写就跟随操作者：终端里跟 `BM2_LANG` / `LC_ALL` / `LANG`，守护进程自己写的日志跟它的环境。

```toml
name = "api"
script = "index.ts"
instances = 1
port = 3000
lang = "zh"
```

写一个不认识的值会直接报错。

```text
InvalidField: root.lang is not supported: jp
```

这个字段存在的理由很实际：服务器在别的国家、操作者用中文，是常见的组合。

## 两个完整示例

开发阶段单实例、本地端口。

```toml
name = "api-dev"
script = "src/main.ts"
instances = 1
port = 3001
exec_mode = "fork"
restart_delay_ms = 200
min_uptime_ms = 2000
```

线上四实例、共享端口、日志有上界、故障推到飞书。

```toml
name = "api"
cwd = "/srv/api"
script = "dist/server.js"
runtime = "node"
exec_mode = "cluster"
instances = 4
port = 3000
max_memory_mb = 768
max_restarts = 5
restart_delay_ms = 1000
min_uptime_ms = 15000
stop_timeout_ms = 20000
lang = "zh"

[logs]
max_size_mb = 50
keep = 7

[notify]
enabled = true
lang = "zh"
daily_report_hour = 9
threshold_rss_percent = 85
threshold_disk_mb = 2048

[[notify.target]]
platform = "feishu"
url = "__BM2_FEISHU_WEBHOOK__"

[[notify.target]]
platform = "email"
to = ["oncall@example.com"]
events = ["errored", "reuseport_missing"]
```

## 错误长什么样

配置错误由两层组成：解析层报位置，校验层报字段与原因。

```text
bm2: InvalidDocument: cannot read config file: /srv/api/bm2.toml
bm2: InvalidField: project api: instances must be between 1 and 1024
bm2: InvalidField: project api: logs.max_size_mb must be between 1 and 102400
```

`bm2` 前缀只在错误由 CLI 自己产生时出现。守护进程回的错误不带前缀（例如 `unknown app: api`、`port conflict: ...`）——这也是排查「到底哪一侧拒绝」的一个线索。
