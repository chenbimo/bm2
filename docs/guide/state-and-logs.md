# 状态与日志

## 状态目录在哪

当前 Linux 用户的 `~/.bm2`。`HOME` 不可用时回退到 `/tmp/bm2-<uid>`。

每个用户一个守护进程，管理这个用户的全部已注册项目。

路径固定，配置无法改变：bm2 按 Linux 用户划分管理范围，而一个可以被指到别处的守护进程，会心安理得地把同一批应用管上两遍。

目录权限 `0700`。守护进程启动时会校验属主，目录属于别的 uid 就拒绝启动——里面放着控制守护进程的令牌，不能让别人读到。

## 目录布局

```text
~/.bm2/
├── daemon.endpoint                 # 控制通道：第一行端口，第二行令牌
├── bm2d.lock                       # 同一时刻只有一个守护进程
├── bm2d.pid                        # 守护进程 PID
├── upgrade.lock                    # 同一时刻只有一个升级
├── bm2d.log                        # 守护进程 stderr 与诊断
├── bm2d.events.jsonl               # 守护进程与监督事件
├── bm2.events.jsonl                # CLI 连接与重试事件
└── projects/
    └── <name>/
        ├── project.json            # 项目登记：配置路径、模式、停止标记
        ├── state-<id>.json         # 单实例状态
        ├── .tempLogs/              # 实例暂存：应用直接写，收集后清空
        │   ├── <name>-<id>.out.log
        │   ├── <name>-<id>.err.log
        │   └── <name>-bm2.err.log  # bm2 自己的崩溃/重启记录
        └── logs/
            ├── <name>-<日期>.log           # 普通日志（所有实例合并）
            ├── <name>-<日期>.1.log         # 当天超量后的分片
            ├── <name>-<日期>.error.log     # 错误日志
            └── <name>-<日期>.error.1.log
```

几个文件的作用值得单独说。

`daemon.endpoint` 是控制通道的入口，两行：回环端口与访问令牌。两行写在同一个文件里并原子替换，所以客户端不会把上一代守护进程的端口和下一代的令牌配到一起。

`bm2d.lock` 是 `flock`。持有者退出即释放，`SIGKILL` 也一样，所以崩溃不会留下永久锁。

`project.json` 记三样：配置文件路径、启动模式、是否被 `stop` 停止。它是守护进程重启后能否把项目照原样恢复的依据。

`state-<id>.json` 记一个实例的 pid、启动时间、累计启动次数、连续重启次数、最后一次退出码与信号。它只用于「守护进程重启后认领仍在运行的进程」，不记日志、不记环境变量值、不记配置内容。

## 日志：一个项目每天两个文件

项目日志按「日期 + 大小」两级切分，**与实例数无关**：50 个实例也只在 `logs/` 里留下当天那一两个文件。

| 文件 | 内容 |
| --- | --- |
| `<name>-<日期>.log` | 应用 stdout，所有实例合并 |
| `<name>-<日期>.error.log` | 应用 stderr 与 bm2 的崩溃/重启记录 |
| `<name>-<日期>.1.log` | 当天文件超过 `max_size_mb` 后的第一个分片，依次 `.2`、`.3` |

每一行都带时间戳与来源：

```text
2026-11-22T14:35:12.345Z [0] GET /api/user/profile 200 12ms
2026-11-22T14:35:12.401Z [3] TypeError: Cannot read properties of undefined
2026-11-22T14:35:13.900Z [bm2] 实例 0 异常退出 退出码=1 原因=exit_code 重启次数=3
```

`[n]` 是实例号，`[bm2]` 是 bm2 自己写的。看日志的人不需要知道哪个文件属于哪个进程。

看当天的日志：

```bash
bm2 logs api         # 普通日志
bm2 logs api -e      # 错误日志
bm2 logs api -f      # 持续跟随
```

## 应用输出怎么变成项目日志

应用仍然只写自己的文件，bm2 负责搬运：

1. spawn 时把 stdout/stderr 指到 `.tempLogs/<name>-<id>.out.log` / `.err.log`（`O_APPEND` 打开）
2. 收集任务每秒一轮：读走内容 → 加时间戳与 `[实例号]` 前缀 → 追加到当天的项目日志 → 清空暂存
3. 清空是安全的：`O_APPEND` 保证应用下一次写落在偏移 0，不会产生空洞

这样守护进程崩了也不影响业务：应用只是继续往自己的文件里写，下次守护进程起来再把这段补进项目日志。

搬运用「先落盘副本再清空源」：副本写完才动源文件，任何一步崩了都能重来；清空之前会核一次大小，同步期间又写进来的字节记成 `log_dropped` 事件，不静默丢。

## 轮转

- **跨天**：新建当天的文件，旧的留着
- **当天超量**：`<name>-<日期>.log` 改名成 `.1.log`，原来的 `.1` 往后挪，再新建空文件继续写
- **清理**：`keep_days` 保留最近几个「有日志的日期」，更早的连同分片一起删

因为项目日志只有 bm2 一个写者，轮转用 `rename` 换文件，不像应用持有 fd 时那样需要 copytruncate，也就不会丢掉换文件那一刻写进来的字节。

## 轮转配置

```toml
[logs]
max_size_mb = 50
keep_days = 7
```

- `max_size_mb` 是单个文件的阈值，单位 MiB。当天文件超过它就分片。
- `keep_days` 保留最近几个「有日志的日期」，两条流各算各的。`0` 表示不清理。
- 分片文件名带数字后缀：`.1` 是最新的一份，`.2` 更旧，依次类推。

守护进程自己的三份日志（两份事件日志与 stderr）不属于任何项目，不受项目 `[logs]` 支配，统一用内置策略：`10 MiB`，改名轮转，代数不限。其中 `bm2d.log` 由守护进程自己持有 fd，只能用拷贝截断的方式。

## 该留多少

按项目量估：一个实例每秒写 `2 KB`，一天约 `170 MB`。

`max_size_mb = 50` 配 `keep_days = 7` 意味着单个项目最多约 `7 × 2 × 50 MB = 700 MB`（每天普通 + 错误各一份，七天）。这个估算与实例数无关——实例越多，单个文件消耗越快，但文件数量不变。

只想留近期历史就把 `keep_days` 设小；`0` 表示永远不清理。

## 怎么看日志

一个项目当天只有两个文件，不用挑实例：

```bash
bm2 logs api          # 普通日志（所有实例合并，带 [实例号]）
bm2 logs api -e       # 错误日志，含崩溃与重启记录
bm2 logs api -f       # 持续跟随，Ctrl+C 只停止跟随
```

想直接读文件也可以：

```bash
tail -f ~/.bm2/projects/api/logs/api-2026-11-22.log
tail -50 ~/.bm2/projects/api/logs/api-2026-11-22.error.log
```

`bm2 dev` 会把当天日志跟到终端，第一行会说明「Ctrl+C 只停止跟随，应用继续运行」。

## 崩溃日志的格式

一行一条，写进错误日志，以 `[bm2]` 标记来源。

```text
2026-11-22T14:35:13.900Z [bm2] 实例 0 pid=48213 原因=exit_code 退出码=1 重启次数=3
2026-11-22T14:40:02.100Z [bm2] 实例 0 pid=48213 原因=signal 信号=SIGKILL 重启次数=4
2026-11-22T14:52:11.700Z [bm2] 实例 0 pid=48213 原因=memory_limit 内存=612MB 上限=512MB 重启次数=1
```

`原因` 的取值：

| 值 | 含义 |
| --- | --- |
| `exit_code` | 非零退出码 |
| `signal` | 被信号杀掉 |
| `quick_exit` | 退出码 0，但没活过 `min_uptime_ms` |
| `terminated` | 收养的进程退出，拿不到退出码（`ECHILD`） |
| `memory_limit` | RSS 超过 `max_memory_mb`，被 bm2 按异常重启处理 |
| `spawn_failed` | 进程拉不起来 |
| `reuseport_missing` | cluster 模式没开 `reusePort`，项目被整体停下 |
| `pid_conflict` | 记录里的 pid 被别的程序占用，拒绝接管 |

崩溃日志只记异常与需要人工介入的事件。人工停机不会写它，那些原因（`stop_requested`、`manual_remove`、`manual_kill`）只出现在实例的 `last_reason` 与 `list --json` 里。

`memory_limit` 那一行会额外带 `rssMb` 与 `limitMb`，因为「超了多少」正是排查时要看的数字。

## 事件日志

两个 `*.events.jsonl`，每行一个 JSON 对象。

它们只记管理元数据：时间戳、事件名、项目、实例、pid、原因。**不含**环境变量值、协议载荷、应用输出，也不含通知凭据。

`bm2d.events.jsonl` 是主线索。

```bash
tail -f ~/.bm2/bm2d.events.jsonl
jq -c 'select(.event=="reuseport_missing")' ~/.bm2/bm2d.events.jsonl
```

常见事件：

| 事件 | 含义 |
| --- | --- |
| `daemon_starting` / `daemon_stopping` / `daemon_stopped` | 守护进程生命周期 |
| `daemon_detaching` / `daemon_detached` | `reload` 或 `upgrade` 的换班 |
| `recovery_complete` | 启动后的注册恢复与进程认领完成 |
| `instance_started` / `instance_exited` | 实例的拉起与退出 |
| `instance_adopted` | 守护进程重启后接管了仍在运行的实例 |
| `instance_restart_scheduled` | 已安排重启，detail 写明原因 |
| `instance_errored` | 预算耗尽或需要人工介入，停止自愈 |
| `memory_limit` | 内存超限 |
| `reuseport_confirmed` / `reuseport_missing` / `reuseport_probe_stopped` | cluster 端口组探测的三种结局 |
| `pid_conflict` | 记录里的 pid 属于别的程序 |
| `project_removed` | 项目已从名册移除 |
| `state_save_failed` / `state_load_failed` / `state_discarded` | 状态文件的读写与丢弃 |
| `notify_sent` / `notify_target_failed` | 逐目标的投递结果，detail 带事件、目标与失败原因 |
| `notify_partial` / `notify_failed` | 整条消息的结果：部分成功，或全部失败要重试（detail 带第几次尝试） |
| `notify_rate_limited` / `notify_queue_full` / `notify_backlog_dropped` | 通知被限流或丢弃 |
| `connection_refused` / `auth_failed` | 控制面的拒绝 |
| `request_received` / `response_sent` / `command_reply_dropped` | 命令的生命周期 |

`bm2.events.jsonl` 记录 CLI 这一侧：连接、请求、协议重试、过期端点清理。它通常是排查「命令到底发出去没有」的第一处。

## 清理

日志属于项目，随项目走。

- `bm2 remove <name>` 保留日志。
- `bm2 remove <name> -f` 连状态目录一起删。
- `bm2 clean` 清理没有 `project.json` 的无主目录。

只想清空内容、保留目录：

```bash
: > ~/.bm2/api/logs/api-0.out.log
```

直接删文件也可以，应用下一次写入会重新创建。代价是那一行可能落在新文件里、也可能落在旧 inode 上，取决于轮转正好走到哪一步。最稳的方式还是让轮转去处理。

## 换机器

状态目录里带着旧路径与旧 PID，在新机器上没有意义。更稳的做法是只带走 `logs/`，在新机器重新 `bm2 serve`。

把整份 `~/.bm2` 拷过去时，守护进程启动会按 `project.json` 里的配置路径读配置。路径不存在或配置已变，对应项目会被跳过并记一条 `project_load_failed`，其余项目照常。

拷贝后可能留下无主目录，用 `bm2 clean --dry-run` 看一眼再删。

## 权限与多用户

一个用户一个守护进程，一个状态目录。

被托管的应用以守护进程的用户身份运行：文件权限、`HOME`、日志归属全部跟着走。

不要把 bm2 装在 root 下管理属于其它用户的应用。需要多用户隔离时，每个用户各自安装、各自运行，互不可见。
