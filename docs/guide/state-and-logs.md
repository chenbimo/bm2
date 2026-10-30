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
└── <name>/
    ├── project.json                # 项目登记：配置路径、模式、停止标记
    ├── <name>-<id>.json            # 单实例状态
    └── logs/
        ├── <name>-<id>.out.log     # 应用 stdout
        ├── <name>-<id>.error.log   # 应用 stderr
        └── <name>-<id>.crash.log   # 异常退出诊断
```

几个文件的作用值得单独说。

`daemon.endpoint` 是控制通道的入口，两行：回环端口与访问令牌。两行写在同一个文件里并原子替换，所以客户端不会把上一代守护进程的端口和下一代的令牌配到一起。

`bm2d.lock` 是 `flock`。持有者退出即释放，`SIGKILL` 也一样，所以崩溃不会留下永久锁。

`project.json` 记三样：配置文件路径、启动模式、是否被 `stop` 停止。它是守护进程重启后能否把项目照原样恢复的依据。

`<name>-<id>.json` 记一个实例的 pid、启动时间、累计启动次数、连续重启次数、最后一次退出码与信号。它只用于「守护进程重启后认领仍在运行的进程」，不记日志、不记环境变量值、不记配置内容。

## 两类日志，严格分开

`<name>/logs/` 下的三份属于**应用**，由应用自己输出。顶层的三份属于 **bm2**，记录管理侧做了什么。

分开的好处很直接：对应用日志 `tail -f` 读到的全是应用输出。管理侧的历史很小，可以长期保留。

出问题时这个划分尤其有用。应用崩了，它写自己的 `.error.log` 与 `.crash.log`。「要不要重启、为什么」记在 `bm2d.events.jsonl` 里。

## 轮转

守护进程每 `10s` 检查一次所有日志的体积，超过阈值就轮转。

阈值来自项目自己的 `[logs]`：

```toml
[logs]
max_size_mb = 50
keep = 7
```

- `max_size_mb` 是单个文件的阈值，单位 MiB。
- `keep` 是保留的归档代数。`7` 表示 `.1 ~ .7`，超出部分从最旧的删起。
- `keep = 0` 表示代数不限，磁盘占用的唯一上界就是你设的大小。

归档文件名带数字后缀：`.1` 是最新的一份归档，`.2` 更旧，依次类推。

两种轮转方式，取决于文件被谁握着。

| 文件 | 方式 | 原因 |
| --- | --- | --- |
| `<name>-<id>.out.log` | 先拷贝再原地截断 | 应用自己持有 fd |
| `<name>-<id>.error.log` | 先拷贝再原地截断 | 同上 |
| `<name>-<id>.crash.log` | 改名 | 由 bm2 自己写 |
| `bm2d.events.jsonl` | 改名 | 由 bm2 自己写 |
| `bm2.events.jsonl` | 改名 | 由 bm2 自己写 |
| `bm2d.log` | 先拷贝再原地截断 | 守护进程持有 fd |

为什么应用的日志不能改名：改名之后应用继续往旧 inode 写，新文件永远是空的，而你看到的「日志」是一条死路。拷贝截断的代价是拷贝与截断之间写入的几行会丢，这是「持有 fd 的日志」必然要付的价钱。

守护进程自己的三份日志不属于任何项目，所以不受任何项目的 `[logs]` 支配，统一用内置策略：`10 MiB`、代数不限。

## 该留多少

按项目量估：一个实例每秒写 `2 KB`，一天约 `170 MB`。

`max_size_mb = 100` 配 `keep = 7` 意味着单实例最多占约 `800 MB`（七个归档加当前文件）。

总占用可以这样估：

```text
max_size_mb × (keep + 1) × 实例数
```

只想留近期历史就把 `keep` 设小。想给磁盘一个明确上界，就给 `keep` 一个具体数字，而不是 `0`。

## 怎么看日志

实时跟随某个实例。

```bash
tail -f ~/.bm2/api/logs/api-0.out.log
```

一次看某个项目的全部标准输出。

```bash
tail -f ~/.bm2/api/logs/*.out.log
```

只看错误。

```bash
tail -50 ~/.bm2/api/logs/api-0.error.log
```

看崩溃原因。

```bash
cat ~/.bm2/api/logs/api-0.crash.log
```

`bm2 dev` 会直接把当前实例的日志跟到终端，第一行会说明「Ctrl+C 只停止跟随，应用继续运行」。

## 崩溃日志的格式

一行一条，键值对，机器可读。

```text
app=api instance=0 pid=48213 reason=exit_code exitCode=1 restartCount=3
app=api instance=0 pid=48213 reason=signal signal=SIGKILL restartCount=4
app=api instance=0 pid=48213 reason=memory_limit rssMb=612 limitMb=512 restartCount=1
```

`reason` 的取值：

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
| `notify_sent` / `notify_partial` / `notify_failed` / `notify_target_failed` | 投递结果 |
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
