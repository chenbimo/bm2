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
├── bm2d.events.log                 # 守护进程与监督事件
├── bm2.events.log                  # CLI 连接与重试事件
└── projects/
    └── <name>/
        ├── project.json            # 项目登记：配置路径、模式、停止标记
        ├── state/                  # 单实例状态，一个实例一个文件
        │   └── <id>.json
        ├── .tempLogs/              # 实例暂存：应用直接写，收集后清空
        │   ├── <name>-<id>.out.log
        │   ├── <name>-<id>.err.log
        │   └── <name>-bm2.err.log  # bm2 自己的崩溃/重启记录
        └── logs/
            ├── <name>.log                  # 普通日志（所有实例合并）
            ├── <name>.1.log                # 上一代，依次 .2 .3
            ├── <name>.error.log            # 错误日志
            └── <name>.error.1.log
```

几个文件的作用值得单独说。

`daemon.endpoint` 是控制通道的入口，两行：回环端口与访问令牌。两行写在同一个文件里并原子替换，所以客户端不会把上一代守护进程的端口和下一代的令牌配到一起。

`bm2d.lock` 是 `flock`。持有者退出即释放，`SIGKILL` 也一样，所以崩溃不会留下永久锁。

`project.json` 记三样：配置文件路径、启动模式、是否被 `stop` 停止。它是守护进程重启后能否把项目照原样恢复的依据。

`state/<id>.json` 记一个实例的 pid、启动时间、累计启动次数、连续重启次数、最后一次退出码与信号。它只用于「守护进程重启后认领仍在运行的进程」，不记日志、不记环境变量值、不记配置内容。

## 日志：一个项目两个文件

项目日志按大小切分，**与实例数无关**：50 个实例也只在 `logs/` 里留下那两三个文件。

| 文件 | 内容 |
| --- | --- |
| `<name>.log` | 应用 stdout，所有实例合并 |
| `<name>.error.log` | 应用 stderr 与 bm2 的崩溃/重启记录 |
| `<name>.1.log` | 上一代，超过 `log_max_size_mb` 后从当前文件挪过来的，依次 `.2`、`.3` |
| `<name>.error.1.log` | 错误日志的上一代，与普通日志各算各的 |

每一行都带时间戳与来源：

```text
2026-11-22T14:35:12.345Z [0] GET /api/user/profile 200 12ms
2026-11-22T14:35:12.401Z [3] TypeError: Cannot read properties of undefined
2026-11-22T14:35:13.900Z [bm2] 实例 0 pid=4021 原因=exit_code 退出码=1 重启次数=3
```

`[n]` 是实例号，`[bm2]` 是 bm2 自己写的。看日志的人不需要知道哪个文件属于哪个进程。

看日志：

```bash
bm2 logs api         # 普通日志
bm2 logs api -e      # 错误日志
bm2 logs api -f      # 持续跟随
```

## 应用输出怎么变成项目日志

应用仍然只写自己的文件，bm2 负责搬运：

1. spawn 时把 stdout/stderr 指到 `.tempLogs/<name>-<id>.out.log` / `.err.log`（`O_APPEND` 打开）
2. 收集任务每秒一轮：读走内容 → 加时间戳与 `[实例号]` 前缀 → 追加到项目日志 → 清空暂存
3. 清空是安全的：`O_APPEND` 保证应用下一次写落在偏移 0，不会产生空洞

这样守护进程崩了也不影响业务：应用只是继续往自己的文件里写，下次守护进程起来再把这段补进项目日志。

搬运用「先落盘副本再清空源」：副本写完才动源文件，任何一步崩了都能重来；清空之前会核一次大小，同步期间又写进来的字节记成 `log_dropped` 事件，不静默丢。

## 轮转

- **超量**：`<name>.log` 满 `log_max_size_mb` 就改名成 `<name>.1.log`，原来的 `.1` 往后挪一代，再新建空文件继续写
- **淘汰**：超出 `log_keep_files` 代的最旧那份被删掉
- **两条流各算各的**：普通日志用满 10 代不影响错误日志的 10 代

因为项目日志只有 bm2 一个写者，轮转用 `rename` 换文件，不像应用持有 fd 时那样需要 copytruncate，也就不会丢掉换文件那一刻写进来的字节。

轮转只看大小，不看日期，所以**时间覆盖是不确定的**：日志安静时一份 10 MB 可能半年不切，吵的时候 10 代也许只覆盖几小时。每行都带毫秒时间戳，找具体时间点靠 `grep '2026-11-22T1[0-2]'`，不依赖文件名。

## 轮转配置

两个键都在顶层，不单独成段。

```toml
log_max_size_mb = 10
log_keep_files = 10
```

- `log_max_size_mb` 是单个文件的阈值，单位 MiB。超过它就轮转。
- `log_keep_files` 保留几代历史，两条流各算各的。`0` 表示不留历史，只留当前那份。
- 分片文件名带数字后缀，代数插在 `.log` 之前：`.1` 是最新的一份，`.2` 更旧，依次类推。

守护进程自己的三份日志（两份事件日志与 stderr）不属于任何项目，不受项目配置支配，统一用内置策略：`10 MiB`，改名轮转，保留 10 代。其中 `bm2d.log` 由守护进程自己持有 fd，只能用拷贝截断的方式。

## 该留多少

按项目量估：一个实例每秒写 `2 KB`，吵起来一天能到 `170 MB`。

`log_max_size_mb = 10` 配 `log_keep_files = 10` 意味着单个项目最多约 `10 MB × (10 + 1) × 2 = 220 MB`（普通 + 错误各一条链）。这个上界与实例数无关——实例越多，单份文件消耗越快，但文件数量与总量不变。

时间覆盖反而不固定：安静时几天也写不满一份，吵时 10 代也许只够几小时。默认 220 MB 是「吵起来」的上界，安静的项目占不满零头；想更省就把 `log_keep_files` 设小，`0` 表示只留当前那份。

## 怎么看日志

一个项目只有两个文件，不用挑实例、不用算今天几号：

```bash
bm2 logs api          # 普通日志（所有实例合并，带 [实例号]）
bm2 logs api -e       # 错误日志，含崩溃与重启记录
bm2 logs api -f       # 持续跟随，Ctrl+C 只停止跟随
```

想直接读文件也可以：

```bash
tail -f ~/.bm2/projects/api/logs/api.log
tail -50 ~/.bm2/projects/api/logs/api.error.log
```

`bm2 dev` 会把项目日志跟到终端，第一行会说明「Ctrl+C 只停止跟随，应用继续运行」。

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

两个 `*.events.log`，每行一条纯文本，格式与项目日志一致：`时间 事件名 字段=值`。

```text
2026-11-22T10:55:48.536Z instance_exited app=demo instance=0 pid=4021 detail=exit_code=1
```

值里带空格时加双引号（`detail="connect refused"`），所以一行始终是一条事件。

它们只记管理元数据：时间戳、事件名、项目、实例、pid、原因。**不含**环境变量值、协议载荷、应用输出，也不含通知凭据。

`bm2d.events.log` 是主线索。

```bash
tail -f ~/.bm2/bm2d.events.log
grep ' reuseport_missing ' ~/.bm2/bm2d.events.log
grep ' instance_exited ' ~/.bm2/bm2d.events.log | grep 'app=demo' | wc -l
```

两个事件日志按大小轮转：10 MiB 一份，保留 10 代。滚动出的文件是 `bm2d.events.1.log`、`bm2d.events.2.log`，文件名里的数字越大越旧，最旧的先删。

常见事件：

| 事件 | 含义 |
| --- | --- |
| `daemon_starting` / `daemon_stopping` / `daemon_stopped` | 守护进程生命周期 |
| `socket_listening` | 控制通道开始监听 |
| `daemon_detaching` / `daemon_detached` | `reload` 或 `upgrade` 的换班 |
| `recovery_complete` | 启动后的注册恢复与进程认领完成 |
| `instance_started` / `instance_exited` | 实例的拉起与退出 |
| `instance_adopted` | 守护进程重启后接管了仍在运行的实例 |
| `instance_restart_scheduled` | 已安排重启，detail 写明原因 |
| `instance_errored` | 预算耗尽或需要人工介入，停止自愈 |
| `memory_limit` | 内存超限 |
| `reuseport_confirmed` / `reuseport_missing` / `reuseport_probe_stopped` | cluster 端口组探测的三种结局 |
| `pid_conflict` | 记录里的 pid 属于别的程序 |
| `reap_overflow` | 待回收的子进程超出队列，丢掉了最旧的一条 |
| `project_load_failed` | 注册信息读不回来，该项目的配置无法恢复 |
| `project_removed` | 项目已从名册移除 |
| `state_save_failed` / `state_load_failed` / `state_discarded` | 状态文件的读写与丢弃 |
| `log_rotated` / `log_rotate_failed` | 守护进程自己的日志轮转，detail 带文件路径 |
| `log_dropped` | 暂存同步瞬间写进来的字节没能搬完，detail 带丢失字节数 |
| `notify_sent` / `notify_target_failed` | 逐目标的投递结果，detail 带事件、目标与失败原因 |
| `notify_partial` / `notify_failed` | 整条消息的结果：部分成功，或全部失败要重试（detail 带第几次尝试） |
| `notify_rate_limited` / `notify_queue_full` / `notify_backlog_dropped` | 通知被限流或丢弃 |
| `notify_forget_dropped` | 去重窗口里已过期的记录没能清掉（只在大量事件时出现） |
| `connection_refused` / `auth_failed` | 控制面的拒绝 |
| `request_received` / `response_sent` / `response_failed` / `command_reply_dropped` | 命令的生命周期 |

`bm2.events.log` 记录 CLI 这一侧：连接、请求、协议重试、过期端点清理。它通常是排查「命令到底发出去没有」的第一处。

## 清理

日志属于项目，随项目走。

- `bm2 remove <name>` 保留日志。
- `bm2 remove <name> -f` 连状态目录一起删。
- `bm2 clean` 清理没有 `project.json` 的无主目录。

只想清空内容、保留目录：

```bash
: > ~/.bm2/projects/api/logs/api.log
```

清空是安全的：收集任务下一轮从偏移 0 继续写，不会留下空洞。真要丢掉全部历史，连代数一起删：

```bash
rm ~/.bm2/projects/api/logs/api.*.log
```

别只删当前那份而留着 `.1`、`.2`：它们会在下次轮转时接着被往后挪。想彻底重来就整个删掉 `logs/`，收集任务会重新建目录。

## 换机器

状态目录里带着旧路径与旧 PID，在新机器上没有意义。更稳的做法是只带走 `logs/`，在新机器重新 `bm2 serve`。

把整份 `~/.bm2` 拷过去时，守护进程启动会按 `project.json` 里的配置路径读配置。路径不存在或配置已变，对应项目会被跳过并记一条 `project_load_failed`，其余项目照常。

拷贝后可能留下无主目录，用 `bm2 clean --dry-run` 看一眼再删。

## 权限与多用户

一个用户一个守护进程，一个状态目录。

被托管的应用以守护进程的用户身份运行：文件权限、`HOME`、日志归属全部跟着走。

不要把 bm2 装在 root 下管理属于其它用户的应用。需要多用户隔离时，每个用户各自安装、各自运行，互不可见。
