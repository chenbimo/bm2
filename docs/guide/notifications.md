# 通知

bm2 可以把运行情况上报出去。

配置属于**项目**，写在同一份 `bm2.toml` 的 `[notify]` 段，改动在下一次 `bm2 serve` 时生效。

每个项目只上报自己的事件、只发给自己配置的目标。没写 `[notify]` 的项目完全不上报。

投递是内置的：HTTPS 与 SMTP 都在 bm2 内部实现，不需要 `curl`，也不依赖任何外部命令。

```bash
bm2 notify    # 在项目目录执行：给配置的目标发一条测试消息
```

## 主表字段

| 字段 | 类型 | 默认 | 约束 | 作用 |
| --- | --- | --- | --- | --- |
| `enabled` | 布尔 | `false` | `true` / `false` | 总开关 |
| `lang` | 字符串 | 跟随项目 `lang` | `en` / `zh` | 发出去的消息用什么语言 |
| `timeout_ms` | 整数 | `5000` | `100 ~ 60000` | 单个目标的硬超时 |
| `dedupe_window_s` | 整数 | `3600` | `0 ~ 604800`，`0` 关闭 | 同一告警在这个秒数内只发一条 |
| `max_per_minute` | 整数 | `30` | `0 ~ 6000`，`0` 不限 | 每分钟即时上报上限（按项目计） |
| `queue_size` | 整数 | `128` | `1 ~ 4096` | 即时上报的待投递队列深度（按项目计），满时丢最新 |
| `events` | 字符串数组 | `[]` | 见下文事件表 | 事件总闸 |
| `threshold_rss_percent` | 整数 | `0` | `0 ~ 100` | RSS 占 `max_memory_mb` 的百分比 |
| `threshold_offline_min` | 整数 | `0` | `0 ~ 1440` | 实例非 online 持续分钟数 |
| `threshold_restarts` | 整数 | `0` | `0 ~ 1000` | 连续异常重启次数 |
| `start_timeout_ms` | 整数 | `0` | `0 ~ 600000` | 拉起后端口仍未监听的毫秒数 |
| `threshold_disk_mb` | 整数 | `0` | `0 ~ 1048576` | 状态盘剩余空间下限 |
| `threshold_storm` | 整数 | `0` | `0 ~ 1000` | 十分钟窗口内的重启次数 |
| `mail_url` | 字符串 | — | `smtp://` 或 `smtps://` | SMTP 地址，`email` 端点共用 |
| `mail_from` | 字符串 | — | 非空 | 发件人地址，`email` 端点必需 |
| `mail_username` | 字符串 | — | — | 中继需要认证时的用户名 |
| `mail_password` | 字符串 | — | — | 中继需要认证时的密码 |

所有阈值默认都是 `0`，表示关闭。

`lang` 只影响发往聊天工具与邮箱的文案。事件日志、状态文件与 JSON 保持语言中立，因为读它们的既有工具也有人。

`lang` 不写时跟随项目的 `lang`：`lang = "zh"` 的项目，通知也是中文。`[notify] lang` 可以覆盖它，因为群和终端可能想用不同语言。

## 上报条目

一条上报 = 一个行为 + 一组目标。写在 `[[notify.report]]` 里，两类互斥。

**即时上报**由事件驱动，没有 `cron`。事件命中时立即发出，经过去重、限流、队列与重试。

**周期上报**有 `cron` 与 `template`。到点即发，直通投递，不去重也不限流。

| 字段 | 必填 | 适用 | 说明 |
| --- | --- | --- | --- |
| `name` | 是 | 两类 | 项目内唯一，`bm2 notify <name>` 用的就是它 |
| `label` | 否 | 两类 | 用途标识，仅给人看 |
| `events` | 否 | 仅即时 | 覆盖 `[notify] events` 总闸 |
| `min_level` | 否 | 仅即时 | `info` / `warn` / `error`，只收该级别及以上 |
| `cron` | 是（周期） | 仅周期 | 标准五字段表达式 |
| `template` | 是（周期） | 仅周期 | `health` 或 `stats` |
| `target` | 是 | 两类 | 至少一个 `[[notify.report.target]]` |

写在周期上报上的 `events` 或 `min_level` 会被**拒绝**，而不是被忽略——一份看起来生效、实际不生效的配置比报错更难查。

`cron` 与 `template` 必须成对出现，只有一个也是错误。

### cron 写法

五个字段：分、时、日、月、周。

| 字段 | 范围 | 说明 |
| --- | --- | --- |
| 分 | `0 ~ 59` | |
| 时 | `0 ~ 23` | |
| 日 | `1 ~ 31` | |
| 月 | `1 ~ 12` | |
| 周 | `0 ~ 7` | `0` 与 `7` 都是周日 |

每个字段支持四种写法：`*`、`*/n`、单个数字、逗号列表。

```toml
cron = "*/5 * * * *"      # 每 5 分钟
cron = "0 8 * * *"        # 每天 08:00
cron = "0 9,18 * * 1"     # 周一 09:00 与 18:00
```

不支持区间（`1-5`）与区间步长（`1-5/2`）。需要多个值时用逗号列出来。

日与周不能同时受限。`0 0 1 * 1` 这种写法会被拒绝，因为不同 cron 实现对此解释不一致。

时间取本机本地时区。

## 模板内容

| `template` | 内容 |
| --- | --- |
| `health` | 全量体检：逐实例一行（状态、端口、内存、峰值、CPU、运行时长、重启次数），另附项目汇总（在线数、异常数、模式、端口、磁盘、负载） |
| `stats` | 同样的布局，另附自上一份统计以来的内存峰值与自动重启次数 |

```toml
[[notify.report]]
name = "健康巡检"
cron = "*/5 * * * *"
template = "health"

[[notify.report]]
name = "每日统计"
cron = "0 8 * * *"
template = "stats"
```

## 端点

每条上报带一组投递端点，`platform` 七选一。

| `platform` | 必填 | 可选 | 说明 |
| --- | --- | --- | --- |
| `feishu` | `url` | `secret`、`format` | `secret` 用于加签 |
| `dingtalk` | `url` | `secret`、`format` | `secret` 用于加签，签名拼在 URL 上 |
| `wecom` | `url` | `format` | 企业微信群机器人 |
| `slack` | `url` | `format` | |
| `discord` | `url` | `format` | |
| `webhook` | `url` | `secret`、`format` | `secret` 作为 `Authorization: Bearer` |
| `email` | `to` | — | 地址与凭据来自 `mail_*` |

端点字段：

| 字段 | 说明 |
| --- | --- |
| `platform` | 七选一，闭集 |
| `url` | `http://` 或 `https://` 开头。`email` 不写 |
| `secret` | 加签密钥或 Bearer 令牌，按平台含义不同 |
| `format` | `text` / `markdown` / `card` |
| `to` | 仅 `email`：收件人数组，不能为空 |

`format` 默认值：`feishu`、`dingtalk`、`wecom`、`slack`、`discord` 是 `markdown`，其余是 `text`。

`format` 只影响三家聊天平台与 Slack、Discord 的报文形状。`webhook` 与 `email` 忽略它，因为前者有固定的 JSON 结构、后者是纯文本邮件。

`email` 端点用的是主配置里的 `mail_url`、`mail_from`、`mail_username`、`mail_password`。没有 `mail_url` 或 `mail_from` 却在用 `email`，配置阶段就会失败——都到要报警了才发现发不出去，是最不该发生的失败。

`min_level` 只写在**上报条目**上，不能写在端点上：端点字段是闭集，多写一个就报错。

想让某个端点只收更高级别的消息，就为它单独建一条上报条目，用 `min_level` 收窄。下面的例子里值班邮箱只收 `error`。

## 事件

| 事件 | 级别 | 含义 |
| --- | --- | --- |
| `crash` | warn | 异常退出或启动失败，预算未耗尽，退避后重启 |
| `errored` | error | 重启预算耗尽，需要人工 `bm2 serve` |
| `memory_limit` | warn | RSS 超上限，按异常重启处理 |
| `oom_kill` | warn | `SIGKILL` 且内存逼近上限，判定为内核 OOM killer |
| `reuseport_missing` | error | cluster 模式未开 `reusePort`，项目已被停止 |
| `lifecycle` | info | 项目启动、停止、退役，以及干净退出后的按计划重启 |
| `daemon` | info | 守护进程启动，或换班之后接管了本项目 |
| `threshold` | warn | 内存逼近上限、离线过久、重启过频或重启风暴 |
| `disk_pressure` | warn | 状态盘剩余空间不足 |
| `start_timeout` | warn | 拉起之后端口始终没有监听 |

事件的过滤是两级的：`[notify] events` 是总闸，上报条目的 `events` 是第二次筛选，两级都命中才会发。

`oom_kill` 的判定是：收到 `SIGKILL`，并且最近一次采样的 RSS 已达上限的 90%。bm2 自己的 `SIGKILL` 都带明确原因，所以这条通常就意味着内核动手了。

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
threshold_storm = 20

mail_url = "smtps://smtp.example.com:465"
mail_from = "bm2@example.com"
mail_username = "bm2@example.com"
mail_password = "__BM2_MAIL_PASSWORD__"

# 即时上报：故障 → 主群
[[notify.report]]
name = "故障告警"
events = ["crash", "errored", "memory_limit", "oom_kill",
          "disk_pressure", "reuseport_missing", "threshold"]
min_level = "warn"

[[notify.report.target]]
platform = "feishu"
url = "__BM2_MAIN_WEBHOOK_URL__"

# 即时上报：只有 error 级故障才打值班邮箱
[[notify.report]]
name = "值班告警"
events = ["crash", "errored", "memory_limit", "oom_kill",
          "disk_pressure", "reuseport_missing", "threshold"]
min_level = "error"

[[notify.report.target]]
platform = "email"
to = ["oncall@example.com"]

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
platform = "slack"
url = "__BM2_STATS_WEBHOOK_URL__"
```

## 投递行为

**按项目隔离。** 每个项目只上报自己的事件，收件人只来自自己的配置。一个项目不能替另一个项目上报。

**凭据零泄露。** 失败原因、事件日志与 CLI 输出永不包含 `url`、`secret` 或 `password`。校验错误只报字段名与 `target[i]` 下标。

**投递是独立任务。** 监督循环只把渲染好的消息放进内存队列就返回，不渲染、不等待。端点慢、端点挂、网络抖，延迟的只有投递——内存采样、崩溃重启、停止超时都不受影响。

**即时上报**依次经过去重、限流、队列，然后投递。

- 去重按「项目 + 实例 + 事件」签名，窗口内重复的只计次数不发消息。
- 窗口过去后第一条照发，并在正文里补一句「上一个窗口内同样的事件共 N 次」。
- 限流按项目计，滚动 60 秒，不跨项目累计。
- 队列也按项目计，满了丢最新的，保留最开始的那批——它们才是根因。
- 最多三次投递尝试，退避递增：失败后 5 秒重试，再失败 15 秒后重试，第三次失败即丢弃。
- 多个目标部分成功时不重试，避免给成功的那几个重复发。

**周期上报**到点直发，不去重、不限流、不重试，失败只记事件。

**`bm2 notify` 的测试消息**绕过事件筛选、去重与限流，直接投递，逐目标回报结果。

**被丢弃的消息只留事件，不留内容。** 排查要看的是丢了多少、什么时候丢，不是丢的内容是什么。相关事件是 `notify_rate_limited`、`notify_queue_full`、`notify_backlog_dropped`，每 60 秒最多一行，detail 里带累计条数。

## 消息长什么样

一条消息由四部分组成：标题、正文、附加字段、页脚。

- 标题会带上项目名：`api · 实例异常退出`。
- 正文是具体描述，比如退出码与重启次数。
- 页脚是 `bm2 @ <主机名>`，方便多台机器共用一个群时区分来源。

`format = "markdown"` 时标题加粗、字段用列表、页脚用引用块。`text` 是同样的内容去掉标记。

## 收不到消息时的四步

1. `enabled` 是不是 `true`。
2. 事件有没有被放行：总闸与条目的 `events` 两级都命中才会发。
3. 端点能不能通：跑 `bm2 notify`，它绕过筛选直接发。
4. `min_level` 有没有卡住：`crash` 是 `warn`，配了 `min_level = "error"` 就收不到。

更完整的排查见[排障与常见问题](/guide/troubleshooting)。
