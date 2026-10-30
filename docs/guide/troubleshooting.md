# 排障与常见问题

这一页按「你会遇到什么」组织，不按模块组织。

遇到问题先看三处：`bm2 list` 的状态、`~/.bm2/<项目名>/logs/` 里的日志、`~/.bm2/bm2d.events.jsonl` 里的事件。

## 守护进程起不来

```text
bm2: bm2d did not start, see /home/u/.bm2/bm2d.log
```

先看那个日志。常见原因有五个。

- `bm2d` 不在 `PATH` 里。两个二进制必须装在同一处，`moon install` 会一起装，手工拷贝时容易只拷一个。
- 当前用户对状态目录没有写权限。
- 状态目录属于另一个 uid。守护进程会拒绝启动，因为里面放的是访问令牌。
- 内核低于 `5.3`。pidfd 是硬依赖，低于这个版本直接拒绝，不会退化运行。
- 已经有一个守护进程在跑。这时手工执行 `bm2d` 会得到：

```text
bm2d: another daemon is already running
```

这是正常保护，不是故障。一个用户只能有一个守护进程。

## 命令没反应

两种不同的失败，处理方式也不同。

**「正在运行但没有响应」。**

```text
bm2d 正在运行,但在 13000ms 内没有响应,请稍后再试
```

守护进程还活着，只是忙（比如正在等一个 `stop_timeout_ms = 60000` 的停止）。不要杀它——杀一个健康的守护进程只会让所有项目失去监督。等一会儿再试。

**端点文件过期。**

守护进程崩溃后可能留下 `daemon.endpoint`。CLI 的处理是：连接失败、确认无人监听，就删掉过期端点、拉起新守护进程、重试一次。所以你通常只会看到命令慢了一下，然后正常返回。

如果一直失败，检查 `~/.bm2/bm2d.log` 与 `~/.bm2/bm2.events.jsonl`。

## 状态是 errored

`errored` 的意思不是「崩了」，而是「bm2 停止自愈了」。

处理顺序：

1. 看 `~/.bm2/<项目名>/logs/<项目名>-<实例号>.crash.log`。
2. 对照 `reason` 找原因。
3. 修好之后回到项目目录 `bm2 serve`。

`bm2 serve` 会重建实例数组并把重启预算清零。

常见 `reason`：

| `reason` | 原因 | 怎么修 |
| --- | --- | --- |
| `exit_code` | 应用非零退出 | 看 `error.log`，通常是缺依赖或配置错 |
| `signal` | 被信号杀掉 | 常见是 OOM，对照 `oom_kill` 事件 |
| `quick_exit` | 退出码 0 但没活过 `min_uptime_ms` | 应用启动后立刻自己退了，检查启动逻辑 |
| `memory_limit` | RSS 超 `max_memory_mb` | 调高上限或查泄漏，别只调上限 |
| `spawn_failed` | 进程拉不起来 | 脚本路径、运行时是否在 `PATH`、权限 |
| `reuseport_missing` | cluster 模式没开 `reusePort` | 见下一节 |
| `pid_conflict` | 记录的 pid 被别的程序占用 | 罕见，通常发生在手工 `kill` 与接管之间 |

预算耗尽只是「不再自动重试」，项目仍在册、日志仍在，随时可以再来一次。

## cluster 模式启动即失败

全部实例 `errored`，执行模式列是 `cluster`，`crash.log` 里是 `reason=reuseport_missing`。

原因只有一句话：应用没打开 `reusePort`。

Bun 的写法。

```ts
Bun.serve({
  port: Number(process.env.BM2_APP_PORT),
  reusePort: true,
  fetch: () => new Response("ok"),
})
```

Node.js 的写法。

```js
const http = require("node:http")

const port = Number(process.env.BM2_APP_PORT)
http
  .createServer((req, res) => res.end("ok"))
  .listen({ port, reusePort: true })
```

注意不是 `node:cluster` 模块。bm2 不用 Node 的 cluster，也不需要应用 fork 工作进程。

两个容易忽略的点：

- 应用只绑 `127.0.0.1` 时，探测在 `0.0.0.0` 上做，地址不匹配可能被判为独占。改绑所有地址，或改用 `fork` 模式。
- 只有一个实例也要开 `reusePort`。`cluster` 的探测不因为实例数是 1 就跳过。

不想改应用就换模式。

```toml
exec_mode = "fork"
```

代价是网关要为每个实例写一条 upstream。

## 端口冲突

```text
port conflict: api port range 3000~3001 overlaps web 3001~3001
```

同一台机器上所有在册项目的端口范围不能重叠。

- `cluster` 项目只占一个端口槽。
- `fork` 项目占 `instances` 个。

三种改法：换起始端口、减实例数、先 `bm2 remove` 不用的项目。

启动前可以先探测一次。

```bash
bm2 check
```

它会说明每个端口是空闲、被共享监听者占着（能加入 cluster），还是被独占监听者占着（不能加入）。

```text
port 3000: already held by a shared listener
```

注意本项目自己正在运行的实例也会出现在这里。

## 实例反复重启

先看 `crash.log`，再看 `error.log`。最常见的六种原因：

- **脚本路径写错。** `script` 相对的是 `cwd`，默认是 `bm2.toml` 所在目录。`bm2 check` 会直接指出文件不存在。
- **依赖没装。** 应用目录里缺 `node_modules`，或用了 `bun install` 却没在部署机上跑。
- **运行时版本低于下限。** Bun `1.4.0`、Node.js `24.0.0`。这类失败发生在登记之前，项目根本不会进名册。
- **环境变量缺失。** 比如 `process.env.DATABASE_URL` 是 `undefined`，启动即抛错。注意模式：`serve` 读 `.env.production`，`dev` 读 `.env.development`。
- **监听端口写死。** 没读 `BM2_APP_PORT`。fork 模式下多实例会互相抢端口。
- **应用启动后立刻退出。** 表现为 `quick_exit`，通常是有前置检查没过。

如果重启次数很多但一直没到 `errored`，那说明每次都能活过 `min_uptime_ms` 再崩——这通常意味着应用在处理某个周期性任务时挂掉，而不是启动失败。

## 日志在哪里

```text
~/.bm2/<项目名>/logs/
├── <项目名>-0.out.log     标准输出
├── <项目名>-0.error.log   标准错误
└── <项目名>-0.crash.log   崩溃诊断
```

每个实例三个文件，按编号分开。

没有 `crash.log` 是好事：它只在异常退出或启动失败时写。

`~/.bm2/bm2d.log` 是守护进程自己的输出，`~/.bm2/bm2d.events.jsonl` 是事件流。

日志超过 `[logs] max_size_mb` 会轮转成 `.1`、`.2`，`keep = 0` 表示代数不限。检查间隔是 `10s`，所以刚刚写满的文件最多等十秒才轮转。

## 通知收不到

按这四步排查，能覆盖绝大多数情况。

1. `enabled` 是不是 `true`。默认关闭。
2. 事件有没有被放行。`[notify] events` 是总闸，上报条目的 `events` 是第二次筛选，两级都命中才会发。
3. 端点能不能通。跑 `bm2 notify`，它绕过筛选直接投递。能收到说明端点与凭据没问题，问题在筛选。
4. `min_level` 有没有卡住。`crash` 是 `warn`，配成只收 `error` 就收不到。

剩下的属于设计行为，不是故障：

- 同一告警在 `dedupe_window_s` 内只发一条，默认一小时。
- 即时上报按项目限流，默认每分钟 30 条。
- 队列满了丢最新的，并记 `notify_rate_limited` / `notify_queue_full`。
- 周期报告到点直发，不去重也不限流，但失败不重试。

## 改了配置没生效

配置在下一次 `bm2 serve` 或 `bm2 dev` 时读取。

`bm2 reload` 只换守护进程，不重读项目配置——它接管的是正在运行的实例，不会重启它们。

所以改实例数、端口、脚本、执行模式、`max_memory_mb` 这类启动期参数，必须重新 `bm2 serve`。

同理，改了 `.env` 也要重新 `serve`：环境是拉起实例时注入的。

## 装了新 Bun 或 Node.js 不生效

守护进程的 `PATH` 在它启动那一刻定格，运行时是按 `PATH` 解析的。

```bash
bm2 reload     # 让新守护进程读新的 PATH
bm2 serve      # 再重启项目
```

只做第二步不够：旧守护进程还是拿旧的 `PATH` 去 `execvpe`。

## 提示协议版本不一致

```text
protocol mismatch: the other side speaks 5, this binary speaks 6; run 'bm2 reload'
```

`bm2` 与 `bm2d` 必须配套。只换了其中一个二进制、或升级中断，就会撞上这个提示。

```bash
bm2 reload
```

两个二进制都在新版本时，这一步就够了。旧守护进程 detach，新守护进程接管仍在运行的实例。

## 名字被占用

```text
app api is already registered by /srv/other-api/bm2.toml; rename the project in bm2.toml, or retire the other one first
```

同一个名字只能属于一份配置。

两条出路：改名，或者先 `bm2 remove api` 把旧的退役，再重新 `serve`。

退役时名字立刻可用，旧项目的统计、重启历史、日志都不会被新项目继承。

## 停止之后又自己起来了

`bm2 stop` 的停止标记是持久化的，守护进程重启、`bm2 reload` 都不会把它带回来。

如果确实又起来了，检查两件事：

- 有没有人又在项目目录执行了 `bm2 serve`。
- 有没有 systemd 单元在拉起这份配置。用 bm2 时，自启单元应该执行 `bm2 serve`，而不是反复重启应用进程。

## 开机后什么都没起来

这是设计行为。bm2 不负责开机自启，守护进程启动时也不会把项目拉起来：它只恢复注册表，并认领仍在运行的实例。

机器重启后实例都不在了，需要有人执行一次 `bm2 serve`。标准做法是给每个项目一个 systemd 用户单元。

```ini
# ~/.config/systemd/user/bm2-api.service
[Unit]
Description=bm2 api
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/srv/api
ExecStart=%h/.moon/bin/bm2 serve
ExecStop=%h/.moon/bin/bm2 stop api

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now bm2-api
loginctl enable-linger $USER
```

## 想清掉退役项目的残留

`bm2 remove` 保留日志，目录也留着。

```bash
bm2 clean --dry-run     # 先看
bm2 clean               # 再删
```

`clean` 只处理**没有 `project.json`** 的目录，也只删 bm2 自己写的文件。目录里有别人的文件时会保留并说明。

```text
bm2: 保留 /home/u/.bm2/api:里面有不是 bm2 写的文件
```

## 换机器之后状态不对

状态目录里带着旧路径与旧 PID，在新机器上没有意义。

更稳的做法是只带走 `logs/`，在新机器重新 `bm2 serve`。

整份拷过去时，配置路径不存在的项目会被跳过并记 `project_load_failed`，其余项目照常恢复。

## 权限与用户

一个用户一个守护进程，一个状态目录。

不要把 bm2 放在 root 下管理属于不同用户的应用：实例会以守护进程的用户身份运行，文件权限、环境变量、日志归属全部跟着走。

需要多用户隔离时，每个用户各自安装、各自运行。

## 在 WSL 里用

可以跑，但它仍然只支持 Linux。

WSL2 是完整内核，pidfd 可用。WSL1 不行。

两个常见差异：WSL 与 Windows 共享端口空间，端口冲突要在两边一起看。WSL 里的进程随发行版实例存活，关掉实例应用就停了，长期服务请放在真正的服务器上。

## 收集诊断信息

报问题时带上这四样。

```bash
bm2 version
bm2 list --json
tail -50 ~/.bm2/bm2d.events.jsonl
tail -20 ~/.bm2/<项目名>/logs/<项目名>-0.crash.log
```

需要稳定语言的输出时固定一次。

```bash
BM2_LANG=en bm2 list --json
```

凭据不会出现在这些输出里：通知的地址、密钥与密码在事件、日志、CLI 输出中都被抹掉，可以放心贴。
