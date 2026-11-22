# bm2

<img src="docs/public/logo.svg" width="141" height="80" alt="bm2 logo">

给 Node.js 与 Bun 项目的进程管理器。

两个原生二进制，空闲占 2.6 MB。

完整手册：https://bm2.moonbitlang.dev

![bm2 架构与执行流程](docs/public/bm2-flow.svg)

## 它解决什么问题

Node.js 项目上服务器，总要一个进程管理器。

pm2 自己也跑在 Node.js 上，带来几个麻烦：

- 空闲常驻约 50 MB 内存
- 多实例中间多一层 cluster master
- 日志轮转要另装插件
- 看管进程一崩，业务跟着停

bm2 用 MoonBit 写成原生二进制，不依赖运行时。

空闲占 2.6 MB，多实例交给内核分流，日志与告警都在里面。

看管进程崩了，业务继续跑。

## 应用场景

- **一台服务器放多个项目**：空闲 2.6 MB，装上不用再管
- **接口要多实例扛并发**：共用端口，网关照旧一条 upstream
- **半夜崩了要有人知道**：故障与恢复都进群
- **每天早上看统计**：不用自己去翻日志
- **换进程管理器怕停业务**：升级不重启应用

## 亮点

| 运行 | 部署 | 运维 |
| --- | --- | --- |
| 异常退出自动重启，失败到上限就停下 | 多实例共用一个端口，内核分发 | 看管进程崩溃，应用继续跑 |
| 升级换版本，进程号不变 | 日志超量自动轮转，按代数保留 | 故障、内存、离线都推到群里 |
| 每天一份运行统计 | 状态与退出原因留档可查 | 配置写错直接点名字段 |

## 安装

```bash
# 装 MoonBit 工具链（只需一次）
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

# 装 bm2
moon install chensuiyi/bm2/...
```

`bm2` 与 `bm2d` 一起装进 `~/.moon/bin`。

安装时在本机编译一次，需要 C 工具链。

运行 bm2 不需要工具链。

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
bm2 dev          # 开发模式：单实例，前台跟日志
```

应用里监听 bm2 分配的端口：

```ts
Bun.serve({ port: Number(Bun.env.BM2_APP_PORT), reusePort: true, fetch: () => new Response('ok') })
```

`reusePort` 只在多实例共用端口时需要。

## 命令速查

| 命令 | 说明 |
| --- | --- |
| `bm2 serve` | 生产模式：登记项目、拉起实例、写状态 |
| `bm2 dev` | 开发模式：单实例、前台跟随日志 |
| `bm2 dev --no-follow` | 同上，但只看启动结果，不跟日志 |
| `bm2 list` | 看实例表：PID、端口、状态、内存、运行时长 |
| `bm2 list [name]` | 只看某个项目 |
| `bm2 list --json` | 机器可读格式，给脚本用 |
| `bm2 check` | 只校验当前目录的 `bm2.toml`，顺带探端口 |
| `bm2 stop [name]` | 停下实例，保留登记，随时能再起 |
| `bm2 remove [name]` | 退役：停下、注销、交还名字，日志保留 |
| `bm2 remove [name] -f` | 退役并删掉状态目录与日志 |
| `bm2 clean` | 清掉状态目录里无主的旧项目 |
| `bm2 clean --dry-run` | 只列出会删什么，不动手 |
| `bm2 reload` | 换入新的看管进程，应用继续跑 |
| `bm2 upgrade` | 升级 bm2 本身，服务不中断 |
| `bm2 notify` | 给本项目所有通知目标发一条测试消息 |
| `bm2 logs <name>` | 看项目日志，`-e` 看错误日志，`-f` 跟随 |
| `bm2 kill -y` | 停掉全部项目并退出看管进程 |

`stop` 是暂停，`remove` 是退役。

`[name]` 不写时，用当前目录 `bm2.toml` 里的项目。

`remove` 默认保留日志，加 `-f` 才连日志一起删。

## 配置文件

没写出来的字段取默认值。

最小可用就四项：

```toml
name = "api"          # 项目名，也是状态目录名
script = "index.js"   # 入口文件，相对 cwd
instances = 4         # 实例数
port = 3020           # 起始端口
```

常用字段与默认值：

| 字段 | 默认 | 什么时候写 |
| --- | --- | --- |
| `cwd` | 配置文件所在目录 | 应用在别处 |
| `runtime` | `bun` | 用 Node 就写 `"node"` |
| `exec_mode` | `cluster` | 要独立端口写 `"fork"` |
| `max_memory_mb` | 512 | 调内存上限与告警线 |
| `max_restarts` | 10 | 调自愈次数，`0` 是首次即停 |
| `restart_delay_ms` | 1000 | 调重启间隔 |
| `min_uptime_ms` | 10000 | 判断"活起来了"的门槛 |
| `stop_timeout_ms` | 10000 | 停机的优雅退出时间 |
| `log_max_size_mb`、`log_keep_files` | 10MB，保留 10 代 | 限制日志占用 |
| `[notify]` | 关闭 | 开告警与日报 |
| `lang` | 跟随操作者 | 钉死输出语言 |

一份改全了的配置，注释说明每个字段的作用：

```toml
name = "api"                # 项目名，也是状态目录名
script = "index.js"         # 入口文件，相对 cwd
instances = 4               # 实例数
port = 3020                 # 起始端口

cwd = "/wwwroot/api"        # 默认是配置目录，应用在别处才写
runtime = "bun"             # 用 Node 写 "node"
exec_mode = "cluster"       # 要独立端口写 "fork"
max_memory_mb = 768         # 单实例内存上限，也是告警基准
max_restarts = 10           # 自愈次数，0 是首次异常即停
restart_delay_ms = 1000     # 异常退出后等多久再拉起
min_uptime_ms = 30000       # 活过这么久才算真的起来了
stop_timeout_ms = 15000     # 停机的优雅退出时间
lang = "zh"                 # 输出与通知语言

log_max_size_mb = 10        # 单个日志文件上限
log_keep_files = 10         # 保留几代历史

[notify]
enabled = true
mail_url = "smtps://smtp.example.com:465"    # 用邮箱才写
mail_from = "bm2@example.com"

[[notify.target]]
platform = "feishu"         # 也可填 email
url = "__FEISHU_WEBHOOK__"
events = ["!lifecycle"]     # 不写就收全部事件
```

凭据用 `__NAME__` 占位符，真值放 `.env` 或启动环境。

其余字段见[配置手册](https://bm2.moonbitlang.dev/guide/configuration)。

## 通知与每日统计

通知属于项目，写在同一份 `bm2.toml` 里。

只有两个概念：哪些事要说，说给谁听。

**七个上报平台**：

| 平台 | `platform` | 需要的字段 |
| --- | --- | --- |
| 飞书 | `feishu` | `url`，可选 `secret` 加签 |
| 钉钉 | `dingtalk` | `url`，可选 `secret` 加签 |
| 企业微信 | `wecom` | `url` |
| Slack | `slack` | `url` |
| Discord | `discord` | `url` |
| 自定义接口 | `webhook` | `url`，可选 `secret` 作令牌 |
| 邮箱 | `email` | `to`，通道写在 `[notify]` |

邮件目标共用 `[notify]` 上的 SMTP 通道。

其余平台都写 `url`，可加 `format` 选报文形状。

**十一个事件**：

| 事件 | 含义 |
| --- | --- |
| `crash` | 实例崩溃，异常退出或启动失败，稍后重启 |
| `errored` | 自愈失败，重启次数用完，停下等人处理 |
| `memory_limit` | 超过 `max_memory_mb`，按异常重启 |
| `oom_kill` | 内存逼近上限时被系统杀掉 |
| `reuseport_missing` | 多实例没开 `reusePort`，项目被停 |
| `lifecycle` | 项目启停，启动、停止、退役、干净退出后重启 |
| `daemon` | 守护进程，看管进程启动或换班接管项目 |
| `threshold` | 阈值告警，内存逼近、离线过久、重启过频或风暴 |
| `disk_pressure` | 磁盘压力，状态盘剩余空间不足 |
| `start_timeout` | 启动超时，拉起后端口一直没监听 |
| `daily_stats` | 每日统计，每天一份运行报告 |

`events` 有三种写法：

- 不写：收全部事件
- `events = ["crash", "oom_kill"]`：只收列出的
- `events = ["!lifecycle"]`：除了列出的都收

两种写法不能混用。

同一件事在 `dedupe_window_s` 内只说一次，默认一小时。

阈值不写就是推荐值，写 `0` 才关闭：

- 内存占上限的 80%
- 实例离线 5 分钟
- 连续重启 5 次
- 拉起后 30 秒端口未监听
- 磁盘剩余不足 1G
- 十分钟内重启 20 次

每日统计默认每天 8 点发一份。

逐实例列出状态、端口、内存、运行时长与重启次数。

不想要就在目标上排除 `daily_stats`。

![](https://static.yicode.tech/images/202611/1795273080601-2f1f.png)

消息跟着项目语言走，中文项目的通知全中文。

改完先 `bm2 check` 看汇总。

再 `bm2 notify` 发条测试消息，确认通道可用。

细节见[通知手册](https://bm2.moonbitlang.dev/guide/notifications)。

## 机制

- `bm2` 是命令行客户端，`bm2d` 在后台看管项目
- 一份 `bm2.toml` 管一个项目，互不干扰
- 看管进程只做三件事：拉起、重启、写状态
- 它退出或升级时应用继续跑，新进程读状态接管
- 状态与事件都落盘，重启后能对上原实例

## 与 pm2 的对比

| 对比项 | bm2 | pm2 |
| --- | --- | --- |
| 形态 | 两个原生静态二进制 | Node.js 应用 |
| 额外依赖 | 无 | 需要 Node.js |
| 空闲看管进程内存 | 约 `2.6 MB` | 约 `50 MB` |
| 日志轮转 | 内置 | 需装 `pm2-logrotate` |
| 多实例分发 | 内核 `SO_REUSEPORT` | cluster master 进程 |
| 看管进程崩溃 | 应用继续运行 | cluster 应用随之中断 |
| 配置 | 静态 TOML，强校验 | `ecosystem.config.js` |

## 环境要求

- Linux，内核 `5.4` 及以上
- Bun `1.4.0`+，或 Node.js `24.0.0`+
- 装 bm2 需要 MoonBit 与 C 工具链，运行不需要

## 联系方式

- 官网与手册：https://bm2.moonbitlang.dev
- 仓库：https://github.com/chenbimo/bm2
- 邮箱：yicode@qq.com
