# bm2

<img src="docs/public/logo.svg" width="141" height="80" alt="bm2 logo">

**Node.js 与 Bun 服务的线上部署工具。两个原生静态二进制：一个命令行，一个守护进程。**

职责只有一件事：把服务拉起来、看住、收好日志、把异常报出去。反向代理交给 Nginx，开机自启交给 systemd。

手册与官网：`https://bm2.moonbitlang.dev`

![bm2 架构与执行流程](docs/public/bm2-flow.svg)

## 亮点

- **崩溃自愈。** 异常退出自动拉起，连续重启有预算，用完就停下等你，不无限重试。
- **两种多实例。** `cluster` 共用一个端口，内核 `SO_REUSEPORT` 分发，没有中间层。`fork` 用连续端口交给网关分流。
- **守护进程崩了，应用不崩。** 新守护进程用 pidfd 认出原进程，校验环境后原地接管。
- **不停机升级。** `bm2 upgrade` 换入新版本，应用 PID 不变。
- **日志内置轮转。** 按项目配大小与代数，不需要额外模块。
- **通知七种渠道。** 飞书、钉钉、企业微信、Slack、Discord、通用 webhook、邮件。HTTPS 与 SMTP 都在内部实现，不调外部命令。
- **日报与巡检。** 用 `cron` 定时推送。`health` 是全量体检：逐实例状态、端口、内存、峰值、CPU、运行时长、重启次数，外加项目汇总。`stats` 再附上自上一份以来的内存峰值与自动重启次数。
- **监控可设阈值。** 内存占用、离线时长、连续重启、启动超时、磁盘余量、重启风暴都能触发告警。同一条告警按窗口去重，上报频率也在配置里限住。
- **状态全落盘。** 谁在跑、跑过几次、为什么退出，都能翻。

## 安装 bm2

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
moon install chensuiyi/bm2/...
```

`bm2` 与 `bm2d` 一起装进 `~/.moon/bin`，不需要再配 `PATH`。

## 快速开始

在项目目录写一份 `bm2.toml`。

```toml
name = "api"
script = "src/index.ts"
instances = 2
port = 3000
```

然后在这个目录执行。

```bash
bm2 serve        # 生产模式：登记、启动、写状态
bm2 list         # 看实例表
bm2 dev          # 开发模式：单实例，前台跟随日志
```

应用里这样监听端口。

```ts
Bun.serve({
  port: Number(Bun.env.BM2_APP_PORT),
  reusePort: true,
  fetch: () => new Response('ok'),
})
```

`reusePort: true` 只在 `cluster` 模式下需要。忘了写的后果很明确：bm2 启动后实测到没生效，会停下整个项目并说明原因，而不是让第二个实例随机发疯。

## 日报与巡检

通知属于项目，写在同一份 `bm2.toml` 里。

```toml
[notify]
enabled = true
events = ["crash", "errored", "memory_limit"]
dedupe_window_s = 3600

[[notify.report]]
name = "每日统计"
cron = "0 8 * * *"
template = "stats"

[[notify.report.target]]
platform = "feishu"
url = "https://open.feishu.cn/open-apis/bot/v2/hook/__FEISHU__"
```

- `health` 适合巡检，看的是当前状态。
- `stats` 适合日报，看的是这一段时间里涨了多少、重启了几次。
- `cron` 支持分、时、日、月、周五个字段，多个值用逗号列出，不支持区间写法。
- 凭据用 `__NAME__` 占位符，真值放 `.env` 或启动环境，别写进仓库。

## 命令速查

| 命令 | 用途 |
| --- | --- |
| `bm2 serve` | 生产模式：登记、启动、写状态 |
| `bm2 dev` | 开发模式：单实例，前台跟随日志，`--no-follow` 关闭跟随 |
| `bm2 stop <name>` | 停下，但保留登记，随时可以再起来 |
| `bm2 remove <name>` | 退役：停下、注销、交还名字，日志默认保留 |
| `bm2 remove <name> -f` | 退役并删除它的状态目录，连日志一起 |
| `bm2 clean` | 清掉状态目录里已经没有归属的旧目录，`--dry-run` 只看不删 |
| `bm2 list [name]` | 查看实例表，`--json` 给机器读 |
| `bm2 check` | 只校验当前目录的 `bm2.toml`，不碰守护进程 |
| `bm2 reload` | 换入新的守护进程，应用继续运行 |
| `bm2 notify [target]` | 给本项目的通知目标发一条测试消息 |
| `bm2 upgrade` | 用 `moon install` 换入新版本并让新守护进程接管 |
| `bm2 kill -y` | 停掉全部项目并退出守护进程 |

`stop` 是暂停，名字还在册。`remove` 是退役，名字交还出去，日志留着，因为想翻日志的时刻往往在项目消失之后。

## 配置速查

```toml
name = "api"                  # 项目名，也是状态目录下的目录名
cwd = "/srv/api"              # 默认是 bm2.toml 所在目录
script = "src/index.ts"       # 相对 cwd
runtime = "bun"               # bun 或 node
exec_mode = "cluster"         # cluster 或 fork
instances = 2
port = 3000
max_memory_mb = 512           # 单实例内存上限，算整棵进程树
max_tree_processes = 512      # 内存统计的进程树上限
max_restarts = 10             # 连续异常重启预算，0 表示首次异常即停止自愈
restart_delay_ms = 1000
min_uptime_ms = 10000
stop_timeout_ms = 10000

[logs]
max_size_mb = 10
keep = 0                      # 0 表示归档代数不限
```

## 与 pm2 的对比

| 对比项 | bm2 | pm2 |
| --- | --- | --- |
| 形态 | 两个原生静态二进制 | Node.js 应用 |
| 额外依赖 | 无 | 需要 Node.js |
| 空闲守护进程内存 | 约 `2.6 MB` | 约 `50 MB` |
| 日志轮转 | 内置 | 需装 `pm2-logrotate` |
| cluster 分发层 | 内核 `SO_REUSEPORT`，无中间层 | cluster master 进程 |
| 守护进程崩溃 | 应用继续运行，新守护进程接管 | cluster 应用随之中断 |
| 配置 | 静态 TOML，字段强校验 | `ecosystem.config.js`，可执行代码 |

## 环境要求

- Linux，内核 `5.4` 及以上。pidfd 进程跟踪与退出码需要它。
- `runtime = "bun"` 需要 Bun `1.4.0` 及以上。
- `runtime = "node"` 需要 Node.js `24.0.0` 及以上。
- 只有安装与升级 bm2 时需要 MoonBit 工具链，运行 bm2 不需要。

版本下限在启动那一刻实测。低于下限会直接拒绝启动并说清缺什么，而不是让实例反复崩溃给你看。
