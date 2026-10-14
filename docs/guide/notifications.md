# 通知

bm2 可以把运行情况上报出去。配置属于**项目**，写在同一份 `bm2.toml` 的 `[notify]` 段，改动在下一次 `bm2 serve` 时生效。每个项目只上报自己的事件、只发给自己配置的目标：一个项目不能替另一个项目上报，没写 `[notify]` 的项目则完全不上报。

投递是内置的——HTTPS 与 SMTP 都在 bm2 内部实现，不需要装 `curl`，也没有一个必须保持可用的外部命令。

```bash
bm2 notify    # 在项目目录执行：给所有目标发一条测试消息
```

## 主配置

| 字段 | 含义 | 默认 |
| --- | --- | --- |
| `enabled` | 总开关 | `false` |
| `lang` | 发出消息的语言：`en` 或 `zh` | `en` |
| `timeout_ms` | 单个目标的硬超时（100–60000） | `5000` |
| `dedupe_window_s` | 同一告警在此秒数内只发一条（0–604800，`0` 关闭） | `3600` |
| `max_per_minute` | 每分钟即时上报上限（0–6000，`0` 不限） | `30` |
| `queue_size` | 即时队列深度（1–4096）；满时丢最新 | `128` |
| `events` | 事件总闸 | `[]` |
| `threshold_rss_percent` | RSS 占 `max_memory_mb` 的百分比（0–100） | `0` |
| `threshold_offline_min` | 实例非 online 持续分钟数（0–1440） | `0` |
| `threshold_restarts` | 连续异常重启次数（0–1000） | `0` |
| `start_timeout_ms` | spawn 后端口仍未监听的毫秒数（0–600000） | `0` |
| `threshold_disk_mb` | 状态盘剩余空间下限（0–1048576） | `0` |
| `threshold_storm` | 十分钟窗口内的重启次数（0–1000） | `0` |
| `mail_url` | `email` 目标的 SMTP 地址（`smtp://` 或 `smtps://`） | — |
| `mail_from` | 发件人地址 | — |
| `mail_username`、`mail_password` | 中继需要认证时的凭据 | — |

所有阈值默认都是 `0`，表示关闭。

`lang` 只影响发往聊天工具或邮箱的文案。CLI、事件日志与 JSON 恒为英文，因为读这些的既有工具也有人。

## 上报条目

一条上报 = 一个行为 + 一组目标。两类互斥。

**即时上报**由事件驱动，没有 `cron`。事件命中 `events` 时立即发出，并且经过去重、限流、队列与重试。

**周期上报**有 `cron` 与 `template`。到点即发，直通投递，不去重也不限流。

`cron` 是标准五字段（分、时、日、月、周），支持 `*`、`*/n`、数字与逗号列表。日与周不可同时受限。

| `template` | 内容 |
| --- | --- |
| `health` | 全量体检：逐实例一行（状态、端口、内存、峰值、CPU、运行时长、重启次数），另附项目汇总（在线、异常、模式、端口、磁盘、负载） |
| `stats` | 同样的布局，另附自上一份统计以来的内存峰值与自动重启次数 |

```toml
[[notify.report]]
name = "健康巡检"
cron = "*/5 * * * *"       # 每 5 分钟
template = "health"

[[notify.report]]
name = "每日统计"
cron = "0 8 * * *"         # 每天 08:00
template = "stats"
```

`name` 必填且在项目内唯一，`label` 是可选的用途标识。即时上报还可以写 `events`（覆盖总闸）与 `min_level`（`info`、`warn`、`error`）。这两项写在周期上报上会被拒绝，而不是被忽略。

## 端点

每条上报带一组投递端点，`platform` 七选一：

| `platform` | 必填 | 可选 |
| --- | --- | --- |
| `feishu` | `url` | `secret`（加签）、`format` |
| `dingtalk` | `url` | `secret`（加签）、`format` |
| `wecom` | `url` | `format` |
| `slack` | `url` | `format` |
| `discord` | `url` | `format` |
| `webhook` | `url` | `secret`（Bearer 令牌）、`format` |
| `email` | `to`（收件人数组） | `format` |

`email` 目标的地址、发件人与凭据来自主配置的 `mail_*` 字段。

端点可以写 `min_level`，表示只接收该级别及以上的消息——下面示例里的值班邮箱只收 `error` 及以上。

## 事件

| 事件 | 级别 | 含义 |
| --- | --- | --- |
| `crash` | warn | 异常退出或启动失败，预算未耗尽，退避后重启 |
| `errored` | error | 重启预算耗尽，需要人工 `bm2 serve` |
| `memory_limit` | warn | RSS 超上限，按异常重启处理 |
| `oom_kill` | warn | SIGKILL 且内存逼近上限，判定为内核 OOM killer |
| `reuseport_missing` | error | cluster 模式未开 `reusePort`，项目已被停止 |
| `lifecycle` | info | 项目启动、停止或退役；干净退出后的按计划重启 |
| `daemon` | info | 守护进程启动，或 reload 之后接管了本项目 |
| `threshold` | warn | 内存逼近上限、离线过久、重启过频或重启风暴 |
| `disk_pressure` | warn | 状态盘剩余空间不足 |
| `start_timeout` | warn | spawn 之后端口始终没有监听 |

`report` 不再是事件：周期内容由 `cron` 与 `template` 表达。

## 完整示例

```toml
[notify]
enabled = true
lang = "zh"
dedupe_window_s = 60
max_per_minute = 60
events = ["lifecycle", "daemon", "crash", "errored", "memory_limit",
          "reuseport_missing", "threshold", "oom_kill", "disk_pressure",
          "start_timeout"]
threshold_rss_percent = 80
start_timeout_ms = 30000
threshold_disk_mb = 1024

mail_url = "smtps://smtp.example.com:465"
mail_from = "bm2@example.com"
mail_username = "bm2@example.com"
mail_password = "__BM2_MAIL_PASSWORD__"

# 即时上报：故障 → 主群 + 值班邮箱
[[notify.report]]
name = "故障告警"
events = ["crash", "errored", "memory_limit", "oom_kill", "disk_pressure", "reuseport_missing"]
min_level = "warn"

[[notify.report.target]]
platform = "feishu"
url = "__BM2_MAIN_WEBHOOK_URL__"

[[notify.report.target]]
platform = "email"
to = ["oncall@example.com"]
min_level = "error"

# 周期上报：健康巡检每 5 分钟 → 监控群
[[notify.report]]
name = "健康巡检"
cron = "*/5 * * * *"
template = "health"

[[notify.report.target]]
platform = "feishu"
url = "__BM2_REPORT_WEBHOOK_URL__"

# 周期上报：每日 8 点统计 → 报表群
[[notify.report]]
name = "每日统计"
cron = "0 8 * * *"
template = "stats"

[[notify.report.target]]
platform = "feishu"
url = "__BM2_STATS_WEBHOOK_URL__"
```

## 投递行为

**按项目隔离。** 每个项目只上报自己的事件，收件人只来自自己的配置。

**凭据零泄露。** 失败原因、事件日志与 CLI 输出永不包含 `url`、`secret` 或 `password`。校验出错只报字段名与 `target[i]` 下标。

**投递是独立任务。** 监督循环不渲染任何东西，也不等待任何东西：它把消息放进内存队列就返回。端点慢、端点挂、网络抖，延迟的只有投递——内存采样、崩溃重启与停止超时都不受影响。

**即时上报**依次经过去重、限流、队列，最多三次投递尝试，退避递增。发送成功则完全静默。

**周期上报**到点直发，不去重也不限流。失败只记事件，不重试。

**被丢弃的消息只留事件，不留内容。** 排查要看的是丢了多少、什么时候丢的，不是丢的内容是什么。
