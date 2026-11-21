# 通知

bm2 可以把运行情况上报出去。

配置属于**项目**，写在同一份 `bm2.toml` 里，改动在下一次 `bm2 serve` 时生效。

只有两个概念：**事件**（哪些事值得说）和**目标**（说给谁听）。每个项目只上报自己的事件、只发给自己配置的目标；没写 `[notify]` 的项目完全不上报。

投递是内置的：HTTPS 与 SMTP 都在 bm2 内部实现，不需要 `curl`，也不依赖任何外部命令。

```bash
bm2 notify    # 在项目目录执行：给本项目所有目标发一条测试消息
```

## 最小示例

```toml
[notify]
enabled = true

[[notify.target]]
platform = "feishu"
url = "__BM2_MAIN_WEBHOOK_URL__"
```

这就够了：目标不写 `events`，表示接收全部事件；每日统计默认在本机时间 `8:00` 发出。想发给多个地方，就再写一个 `[[notify.target]]`。

## 主表字段

| 字段 | 类型 | 默认 | 约束 | 作用 |
| --- | --- | --- | --- | --- |
| `enabled` | 布尔 | `false` | `true` / `false` | 总开关 |
| `lang` | 字符串 | 跟随项目 `lang` | `en` / `zh` | 发出去的消息用什么语言 |
| `timeout_ms` | 整数 | `5000` | `100 ~ 60000` | 单个目标的硬超时 |
| `dedupe_window_s` | 整数 | `3600` | `0 ~ 604800`，`0` 关闭 | 同一告警在这个秒数内只发一条 |
| `max_per_minute` | 整数 | `30` | `0 ~ 6000`，`0` 不限 | 每分钟即时上报上限（按项目计） |
| `queue_size` | 整数 | `128` | `1 ~ 4096` | 即时上报的待投递队列深度（按项目计），满时丢最新 |
| `daily_report_hour` | 整数 | `8` | `1 ~ 23` | 每日统计在本地时间几点发 |
| `threshold_rss_percent` | 整数 | `80` | `0 ~ 100` | RSS 占 `max_memory_mb` 的百分比，`0` 关闭 |
| `threshold_offline_min` | 整数 | `5` | `0 ~ 1440` | 实例非 online 持续分钟数，`0` 关闭 |
| `threshold_restarts` | 整数 | `5` | `0 ~ 1000` | 连续异常重启次数，`0` 关闭 |
| `start_timeout_ms` | 整数 | `30000` | `0 ~ 600000` | 拉起后端口仍未监听的毫秒数，`0` 关闭 |
| `threshold_disk_mb` | 整数 | `1024` | `0 ~ 1048576` | 状态盘剩余空间下限，`0` 关闭 |
| `threshold_storm` | 整数 | `20` | `0 ~ 1000` | 十分钟窗口内的重启次数，`0` 关闭 |
| `mail_url` | 字符串 | — | `smtp://` 或 `smtps://` | SMTP 地址，所有邮件目标共用 |
| `mail_from` | 字符串 | — | 非空 | 发件人地址，用邮件目标时必需 |
| `mail_username` | 字符串 | — | — | 中继需要认证时的用户名 |
| `mail_password` | 字符串 | — | — | 中继需要认证时的密码 |

阈值给的是推荐值：不写就会在达到这个程度时报出来。写 `0` 才是关闭该项；关闭之后，对应事件不会出现。

两个容易混的阈值，看的是两件事：

- `threshold_restarts` 数**连续**异常重启：每次异常退出加一，而一次「干净退出（exit 0）且活过 `min_uptime_ms`」会把它清零。它抓的是「这段一直起不来」。
- `threshold_storm` 数**十分钟滑动窗口内的重启次数**，不管中间有没有成功过，重启够密就报。它抓的是「起来了但一直在抖」——每次都能起，但每隔几分钟就重启一次，`max_restarts` 永远用不完，`threshold_restarts` 也永远到不了线。

两者都触发 `threshold` 事件，级别 warn，只是文案不同。

`lang` 只影响发往聊天工具与邮箱的文案。事件日志、状态文件与 JSON 保持语言中立，因为读它们的既有工具也有人。

`lang` 不写时跟随项目的 `lang`：`lang = "zh"` 的项目，通知也是中文。`[notify] lang` 可以覆盖它，因为群和终端可能想用不同语言。

`enabled = true` 却一个目标都没有，配置阶段就会失败。开关打开却发不出去，是最常见的「以为配好了」。

## 目标

一条 `[[notify.target]]` = 一个投递去处 + 它关心的事件。

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `platform` | 是 | 七选一，闭集 |
| `url` | 网页平台必填 | `http://` 或 `https://` 开头；`email` 不写 |
| `secret` | 否 | 加签密钥或 Bearer 令牌，按平台含义不同 |
| `format` | 否 | `text` / `markdown` / `card` |
| `to` | 邮件平台必填 | 收件人数组，不能为空 |
| `events` | 否 | 这个目标收哪些事件，见下节 |

| `platform` | 必填 | 可选 | 说明 |
| --- | --- | --- | --- |
| `feishu` | `url` | `secret`、`format` | `secret` 用于加签 |
| `dingtalk` | `url` | `secret`、`format` | `secret` 用于加签，签名拼在 URL 上 |
| `wecom` | `url` | `format` | 企业微信群机器人 |
| `slack` | `url` | `format` | |
| `discord` | `url` | `format` | |
| `webhook` | `url` | `secret`、`format` | `secret` 作为 `Authorization: Bearer` |
| `email` | `to` | — | 地址与凭据来自 `mail_*` |

`format` 默认值：`feishu`、`dingtalk`、`wecom`、`slack`、`discord` 是 `markdown`，其余是 `text`。它只影响这几家聊天平台的报文形状；`webhook` 有固定的 JSON 结构、`email` 是纯文本邮件，都忽略它。

`email` 目标用的是主配置里的 `mail_url`、`mail_from`、`mail_username`、`mail_password`。发送通道只有一份，收件人可以多个：每个邮件目标只写自己的 `to`。没有 `mail_url` 或 `mail_from` 却在用 `email`，配置阶段就会失败——都到要报警了才发现发不出去，是最不该发生的失败。

`email` 目标上写 `url`、网页目标上写 `to`，都会被拒绝，而不是被忽略：字段是闭集，写错了就该看见。

## 事件过滤

`events` 有三种写法，一个目标一种：

```toml
# 不写：接收全部事件
[[notify.target]]
platform = "feishu"
url = "__BM2_MAIN_WEBHOOK_URL__"

# 白名单：只收列出来的
[[notify.target]]
platform = "slack"
url = "__BM2_ONCALL_SLACK_URL__"
events = ["crash", "errored", "oom_kill"]

# 排除式：除了列出来的都收
[[notify.target]]
platform = "webhook"
url = "__BM2_BUSY_WEBHOOK_URL__"
events = ["!lifecycle"]
```

- 空数组 `events = []` 是错误：想收全部就别写，想收一部分就列出来。
- 白名单与 `!` 排除不能混写。两种语义相反，混在一起只能靠「谁先谁后」解释，而那种规则没人记得住。
- 事件名是闭集，写错一个会被点名。

`events = ["!lifecycle"]` 是最常用的一种：项目启停不必打扰群里，故障必须知道。

## 事件

事件键是语言中立的，`events` 过滤与机器报文用它；每条通知的字段区首行还会带上它的人类可读名称，按项目的通知语言渲染成中文或英文。所以群里看到的每条消息都写着自己属于哪一类，不用从标题反推。

| 事件 | 中文名 | 英文名 | 级别 | 含义 |
| --- | --- | --- | --- | --- |
| `crash` | 实例崩溃 | Instance crash | warn | 异常退出或启动失败，预算未耗尽，退避后重启 |
| `errored` | 自愈失败 | Restart budget exhausted | error | 重启预算耗尽，需要人工 `bm2 serve` |
| `memory_limit` | 内存超限 | Memory limit exceeded | warn | RSS 超上限，按异常重启处理 |
| `oom_kill` | 内核 OOM 击杀 | Killed by the kernel OOM | warn | `SIGKILL` 且内存逼近上限，判定为内核 OOM killer |
| `reuseport_missing` | 端口复用缺失 | reusePort missing | error | cluster 模式未开 `reusePort`，项目已被停止 |
| `lifecycle` | 项目启停 | Lifecycle | info | 项目启动、停止、退役，以及干净退出后的按计划重启 |
| `daemon` | 守护进程 | Daemon | info | 守护进程启动，或换班之后接管了本项目 |
| `threshold` | 阈值告警 | Threshold alert | warn | 内存逼近上限、离线过久、重启过频或重启风暴 |
| `disk_pressure` | 磁盘压力 | Disk pressure | warn | 状态盘剩余空间不足 |
| `start_timeout` | 启动超时 | Start timeout | warn | 拉起之后端口始终没有监听 |
| `daily_stats` | 每日统计 | Daily statistics | info / warn | 每日统计，内容见下节 |

`oom_kill` 的判定是：收到 `SIGKILL`，并且最近一次采样的 RSS 已达上限的 90%。bm2 自己的 `SIGKILL` 都带明确原因，所以这条通常就意味着内核动手了。

## 每日统计

每日统计也是事件，名叫 `daily_stats`。事件表示「要不要发」，`daily_report_hour` 表示「几点发」，两件事分开写。

统计内容：逐实例一行（状态、端口、内存、峰值、CPU、运行时长、重启次数），另附项目汇总（在线数、异常数、模式、端口、磁盘、负载），以及自上一份统计以来的内存峰值与自动重启次数。

想收到它，就让某个目标接收 `daily_stats`——不写 `events` 时本来就会收到。不想要每日统计，就在每个目标上都排除它：

```toml
[[notify.target]]
platform = "feishu"
url = "__BM2_MAIN_WEBHOOK_URL__"
events = ["!daily_stats"]
```

## 完整示例

```toml
[notify]
enabled = true
lang = "zh"
# 只写偏离推荐值的项：阈值一项没写，就是推荐值
dedupe_window_s = 60
max_per_minute = 60

mail_url = "smtps://smtp.example.com:465"
mail_from = "bm2@example.com"
mail_username = "bm2@example.com"
mail_password = "__BM2_MAIL_PASSWORD__"

# 主群：故障与统计都要
[[notify.target]]
platform = "feishu"
url = "__BM2_MAIN_WEBHOOK_URL__"
events = ["!lifecycle"]

# 监控群：设备状态按原样收，不收启停
[[notify.target]]
platform = "slack"
url = "__BM2_MONITOR_SLACK_URL__"

# 值班邮箱：只收必须有人动手的
[[notify.target]]
platform = "email"
to = ["oncall@example.com"]
events = ["errored", "reuseport_missing"]
```

## 投递行为

**按项目隔离。** 每个项目只上报自己的事件，收件人只来自自己的配置。一个项目不能替另一个项目上报。

**凭据零泄露。** 失败原因、事件日志与 CLI 输出永不包含 `url`、`secret` 或 `password`。校验错误只报字段名与 `target[i]` 下标。

**投递是独立任务。** 监督循环只把渲染好的消息放进内存队列就返回，不渲染、不等待。目标慢、目标挂、网络抖，延迟的只有投递——内存采样、崩溃重启、停止超时都不受影响。

**即时上报**依次经过去重、限流、队列，然后投递。

- 去重按「项目 + 实例 + 事件」签名，窗口内重复的只计次数不发消息。
- 窗口过去后第一条照发，并在正文里补一句「上一个窗口内同样的事件共 N 次」。
- 限流按项目计，滚动 60 秒，不跨项目累计。
- 队列也按项目计，满了丢最新的，保留最开始的那批——它们才是根因。
- 最多三次投递尝试，退避递增：失败后 5 秒重试，再失败 15 秒后重试，第三次失败即丢弃。
- 多个目标部分成功时不重试，避免给成功的那几个重复发。

**每日统计**到点直发，不去重、不限流、不重试，失败只记事件。

**`bm2 notify` 的测试消息**发给全部目标，绕过事件过滤、去重与限流，逐目标回报结果。它的事件键是 `notify_test`（不是 `lifecycle`），名称是「测试消息」，所以按事件筛选的转发规则不会把它误当成真的启停事件。

**被丢弃的消息只留事件，不留内容。** 排查要看的是丢了多少、什么时候丢，不是丢的内容是什么。相关事件是 `notify_rate_limited`、`notify_queue_full`、`notify_backlog_dropped`，每 60 秒最多一行，detail 里带累计条数。

## 消息长什么样

一条消息由四部分组成：标题、正文、附加字段、页脚。

- 标题会带上项目名：`api · 实例异常退出`。
- 字段区首行固定是事件名，其余是这次事件的具体数据。字段名跟随项目语言，中文项目看到的是全中文：

  ```text
  事件: 实例崩溃
  应用: api
  实例: 0
  模式: cluster
  端口: 3100
  进程号: 32402
  状态: online
  启动次数: 10
  崩溃次数: 10
  运行时长: 0s
  ```

  英文项目保持原来的键（`event`、`app`、`project`、`host`、`instance`、`mode`、`port`、`PID`、`status`、`starts`、`crashes`、`uptime`），脚本与既有消费方不用改。项目报文的字段另有 `instances`、`online`、`abnormal`、`load1`、`disk_free`、`peak_mb`、`restarts`。
- 正文字段里的原因码（比如 `quick_exit`、`exit_code`）与状态值（`online`、`stopped`）是语言中立的标识，不翻译——事件日志与 JSON 用的是同一套值，脚本按它们判断。
- 页脚是 `bm2 @ <主机名>`，方便多台机器共用一个群时区分来源。

`format = "markdown"` 时标题加粗、字段用列表、页脚用引用块。`text` 是同样的内容去掉标记。

通用 `webhook` 的 JSON 里同时有两个键：`event` 是语言中立的事件键（`crash`），`event_name` 是同一事件的人类可读名称，与字段区那一行一致。`fields` 里的键跟随项目语言，所以机器消费方应当按 `event` / `event_name` 分支，展示层再读 `fields`。

## 收不到消息时的四步

1. `enabled` 是不是 `true`，有没有至少一个 `[[notify.target]]`。
2. 目标有没有被事件过滤挡住：白名单里少列了一个事件，或者被 `!` 排除了，就是这个原因。
3. 目标能不能通：跑 `bm2 notify`，它绕过筛选直接发给所有目标。
4. 每日统计是不是被排除了：`events = ["!daily_stats"]` 的目标不会收到它。

`bm2 check` 会把通知汇总打出来：几个目标、每日统计在几点发。配置有没有生效，这一行就能看出来。

更完整的排查见[排障与常见问题](/guide/troubleshooting)。
