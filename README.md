# bm2

<img src="docs/public/logo.svg" width="141" height="80" alt="bm2 logo">

**搞定 Node.js 与 Bun 项目的线上部署**

手册与官网：`https://bm2.moonbitlang.dev`

![bm2 架构与执行流程](docs/public/bm2-flow.svg)

## 它解决什么问题

Node.js 项目上服务器，绕不开一个进程管理器。最常见的选择是 pm2，但它自己也跑在 Node.js 上：空闲常驻约 50 MB 内存，多实例中间多一层 cluster master，日志轮转要另装插件，看管进程一崩业务跟着停。

bm2 用 MoonBit 写成两个原生静态二进制，不依赖 Bun、Node 或任何外部命令。空闲只占约 2.6 MB，多实例交给内核分流，日志轮转与告警上报都在里面，看管进程崩了业务继续跑。

## 应用场景

- 一台服务器跑多个 Node.js / Bun 项目，想要一个装上就不用管、不抢资源的进程管理器
- 应用要开多实例扛并发，但不想为分发再引入一层中间层
- 线上出事要第一时间知道：崩溃、内存超限、实例离线、磁盘写满
- 每天早上想收到一份运行统计，而不是自己去翻日志
- 想升级进程管理器，又不愿意为此停一次业务

## 亮点

| 运行 | 部署 | 运维 |
| --- | --- | --- |
| 异常退出自动重启，连续失败会停下来叫人 | 多实例共用一个端口，连接由内核分流 | 看管进程崩溃，业务进程继续运行 |
| 升级换版本，服务不中断、进程号不变 | 日志按大小自动轮转，代数可配 | 崩溃、内存、离线、磁盘等事件自动上报 |
| 每天一份运行统计，逐实例列出状态 | 状态、重启次数与退出原因留档可查 | 配置字段强校验，写错直接点名字段 |

## 安装

bm2 通过 MoonBit 工具链分发，工具链只需装一次，升级 bm2 时不用重装。

```bash
# 1. 装 MoonBit 工具链（`moon` 进 ~/.moon/bin，并写进 shell 配置）
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

# 2. 安装 bm2（bm2 与 bm2d 一起装进 ~/.moon/bin）
moon install chensuiyi/bm2/...
```

安装时会在本机编译一次，没有预编译包，所以需要 C 工具链。运行 bm2 不需要工具链。

## 快速开始

在项目目录写一份 `bm2.toml`：

```toml
name = "api"
script = "src/index.ts"
instances = 2
port = 3000
```

在这个目录执行：

```bash
bm2 serve        # 生产模式：登记、启动、写状态
bm2 list         # 看实例表
bm2 dev          # 开发模式：单实例，前台跟随日志
```

应用里用 bm2 分配的端口号监听：

```ts
Bun.serve({
  port: Number(Bun.env.BM2_APP_PORT),
  reusePort: true,
  fetch: () => new Response('ok'),
})
```

`reusePort` 只在多实例共用端口时需要；单实例不用写。

## 配置文件

没写出来的字段都取默认值，最小可用的配置就是上面那四项。常用的几个：

| 字段 | 默认 | 什么时候要写 |
| --- | --- | --- |
| `cwd` | 配置文件所在目录 | 应用不在配置文件旁边 |
| `runtime` | `bun` | 用 Node 跑：`"node"`（需 Node ≥ 24） |
| `exec_mode` | `cluster` | 每个实例独立端口时改 `"fork"` |
| `max_memory_mb` | 512 | 服务吃得多，或要让内存告警更早/更晚 |
| `max_restarts` | 10 | 想让自愈更快放弃（`0` = 首次异常即停） |
| `stop_timeout_ms` | 10000 | 停机要等更久（如排空连接） |
| `[logs]` | 10MB / 代数不限 | 要限制日志占用 |
| `[notify]` | 关闭 | 要事件告警与每日统计 |

完整字段与取值规则在[配置手册](https://bm2.moonbitlang.dev/guide/configuration)。

示例，一个带日志轮转与告警的真实配置：

```toml
name = "api"
script = "index.js"
instances = 4
port = 3020
max_memory_mb = 768
lang = "zh"

[logs]
max_size_mb = 50
keep = 7

[notify]
enabled = true

[[notify.target]]
platform = "feishu"
url = "__FEISHU_WEBHOOK__"
```

凭据用 `__NAME__` 占位符，真值放 `.env` 或启动环境，不写进仓库。

## 通知与每日统计

通知写在项目的 `bm2.toml` 里，只有两个概念：哪些事要说（事件），说给谁听（目标）。

支持飞书、钉钉、企业微信、Slack、Discord、自定义 webhook 与邮箱。邮件共用 `[notify]` 上的 SMTP 通道，每个目标只写收件人。

会通知的事：

- 异常退出、自愈失败、内存超限、被内核 OOM 杀掉
- 实例离线、连续重启、重启风暴、启动超时
- 状态盘空间不足、端口复用配置不对
- 项目启停、看管进程启动与接管
- 每天的统计报告

目标不写 `events` 就收全部；也可以只收一部分，或排除掉启停这类噪音：

```toml
[[notify.target]]
platform = "feishu"
url = "__FEISHU_WEBHOOK__"
events = ["!lifecycle"]
```

每日统计默认每天 8 点发一份，逐实例列出状态、端口、内存、峰值、CPU、运行时长、重启次数，另外带上区间内的内存峰值与自动重启次数。不想要就在目标上排除 `daily_stats`。

![](https://static.yicode.tech/images/202611/1795273080601-2f1f.png)

改完配置先 `bm2 check` 看汇总，再 `bm2 notify` 发一条测试消息确认通道可用。细节见[通知手册](https://bm2.moonbitlang.dev/guide/notifications)。

## 机制

bm2 由两个进程组成：`bm2` 是你敲命令用的客户端，`bm2d` 是在后台看管项目的常驻进程。

- 项目以配置文件为单位：一份 `bm2.toml` 托管一个项目，项目之间互不影响，各自的配置、状态、日志与告警都是自己的。
- 看管进程只做三件事：拉起实例、按规则重启、把状态写进状态目录。它不做业务逻辑，也不在请求链路上。
- 看管进程退出或升级时，业务进程继续运行；新的看管进程读状态目录，识别已在运行的实例并接着监督。
- 状态与事件都落在磁盘上，所以重启、换版本、机器重启之后都能对上原来的实例。

## 命令速查

| 命令 | 用途 |
| --- | --- |
| `bm2 serve` | 生产模式：登记、启动、写状态 |
| `bm2 dev` | 开发模式：单实例，前台跟随日志 |
| `bm2 list` | 查看实例表，`--json` 给机器读 |
| `bm2 stop <name>` | 停下，保留登记，随时可以再起来 |
| `bm2 remove <name>` | 退役：停下、注销、交还名字，日志默认保留 |
| `bm2 reload` | 换入新的看管进程，应用继续运行 |
| `bm2 upgrade` | 升级 bm2 本身，服务不中断 |
| `bm2 check` | 只校验当前目录的 `bm2.toml` |
| `bm2 notify` | 给本项目所有通知目标发一条测试消息 |
| `bm2 kill -y` | 停掉全部项目并退出看管进程 |

`stop` 是暂停，`remove` 是退役：名字交还出去，日志默认保留。其余参数见[命令手册](https://bm2.moonbitlang.dev/guide/commands)。

## 与 pm2 的对比

| 对比项 | bm2 | pm2 |
| --- | --- | --- |
| 形态 | 两个原生静态二进制 | Node.js 应用 |
| 额外依赖 | 无 | 需要 Node.js |
| 空闲看管进程内存 | 约 `2.6 MB` | 约 `50 MB` |
| 日志轮转 | 内置 | 需装 `pm2-logrotate` |
| 多实例分发 | 内核 `SO_REUSEPORT`，无中间层 | cluster master 进程 |
| 看管进程崩溃 | 应用继续运行，新的看管进程接管 | cluster 应用随之中断 |
| 配置 | 静态 TOML，字段强校验 | `ecosystem.config.js`，可执行代码 |

## 环境要求

- Linux，内核 `5.4` 及以上
- `runtime = "bun"` 需要 Bun `1.4.0` 及以上
- `runtime = "node"` 需要 Node.js `24.0.0` 及以上
- 装 bm2 需要 MoonBit 工具链与 C 工具链；运行 bm2 都不需要

版本下限在启动那一刻实测，低于下限直接拒绝启动并说清缺什么，而不是让实例反复崩溃。
