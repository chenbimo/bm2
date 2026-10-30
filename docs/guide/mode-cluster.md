# cluster 模式：共享端口，内核分发

`cluster` 是 `exec_mode` 的默认值。所有实例监听**同一个端口**，由内核在连接到达时决定交给哪个实例。

没有 master 进程，没有转发层，也没有单点。分发能力来自 Linux 的 `SO_REUSEPORT`。

```toml
name = "api"
script = "src/index.ts"
instances = 4
port = 3000
# exec_mode 省略即 cluster
```

四个实例都监听 `3000`。网关写一条 upstream 就够，实例增减不用动网关。

## 它怎么工作

每个实例在自己的进程里 `listen` 同一个端口，而且都打开了 `SO_REUSEPORT`。内核维护一个端口组，新连接按四元组哈希落到组里某个 socket 上。

三条直接影响运维的事实。

**分发单位是连接，不是请求。** 同一个 HTTP keep-alive 连接上的后续请求仍然落在同一个实例。四个实例不等于四次请求四次轮转，而是四条新连接大致均分。

**没有中间层可以挂。** 内核做分发，所以不存在「分发进程挂掉整站断掉」这种情况。

**实例退出就是离开端口组。** 它持有的监听 socket 关闭，内核把新连接分给剩下的实例。bm2 重启这个实例后，它重新加入组，不需要通知任何人。

## 应用侧必须做的两件事

第一，端口从 `BM2_APP_PORT` 读，不要写死。cluster 模式下每个实例拿到的都是配置里的 `port`。

第二，监听时打开 `reusePort`。这是应用自己的事，因为只有它知道自己的监听方式。

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

Node.js 的 `reusePort` 是 `listen` 的选项，不是 `node:cluster` 模块。bm2 不用 `node:cluster`，也不需要应用自己 fork 工作进程。

运行时版本下限与模式无关：Bun `1.4.0`、Node.js `24.0.0`，低于下限在启动前就被拒绝。

## bm2 怎么验证 reusePort

「应用开了没有」不能靠读配置猜，只能问内核。bm2 在实例进入 online 之后做一次实测。

探测的做法是对同一个端口连做两次 `bind`：

1. 只带 `SO_REUSEADDR` 绑 `0.0.0.0:<port>`。成功说明**没有人在监听**。
2. 端口被占时，再带 `SO_REUSEPORT` 绑一次。成功说明现有监听者允许加入，也就是它开了 `reusePort`。失败于 `EADDRINUSE` 说明现有监听者独占这个端口。

三种结果对应三种处理。

| 探测结果 | 含义 | bm2 的动作 |
| --- | --- | --- |
| 可加入 | 应用开了 `reusePort` | 记为已确认，不再探测 |
| 独占 | 应用没开 `reusePort` | 停止整个项目，全部实例进入 `errored` |
| 无人监听 | 应用还没开始监听 | 每 `500ms` 再试，最多 `60s`。到期停止探测 |

探测间隔 `500ms`，按实例独立进行，首次探测的时间窗口从实例进入 online 起算 `60s`。

慢启动的应用是合法的：只要在 `60s` 内开始监听并且能加入端口组，就不会被误判。超过 `60s` 仍未监听，bm2 只停止探测并记一条 `reuseport_probe_stopped` 事件，不改变实例状态——不监听端口不是 reusePort 的问题，可能是应用压根不是网络服务。

## 检测到独占时会发生什么

处理是项目级的，不是实例级。

1. 记事件 `reuseport_missing`，detail 说明是 cluster 模式缺 `reusePort`。
2. 每个实例的 `crash.log` 写一行 `reason=reuseport_missing`。
3. 全部实例收到 `SIGTERM`，超过 `stop_timeout_ms` 再 `SIGKILL`，最终状态 `errored`，原因 `reuseport_missing`。
4. 项目**保留在册**，只是不再运行。`bm2 list` 仍能看到这些行，供你诊断。
5. 配了通知的话推一条 `reuseport_missing`（`error` 级）。

修好应用之后，回到项目目录再执行一次 `bm2 serve` 即可，注册不会丢，名字不用重新占。

为什么停下整个项目而不是只错一个实例：cluster 的前提就是「大家共用一个端口」。第一个实例独占端口时，第二个实例起来只会拿到 `EADDRINUSE` 并进入无意义的重启循环。一次性停下并点名原因，比让运维从一串 `EADDRINUSE` 里猜要快得多。

## 单实例也照此处理

`instances = 1` 配 cluster 模式是合法的，但 `reusePort` 仍然必须开，探测仍然会跑。

只有一个实例、又不想改应用时，写 `exec_mode = "fork"`。单实例的 fork 与 cluster 在端口上没有区别（都只有 `port` 一个），区别只在于不会再要求 `reusePort`。

## 崩溃与重启

实例之间彼此独立：一个崩了，只有它被重启，其余实例继续服务。

- 重启按 `restart_delay_ms` 延迟，重启预算按实例单独计。
- 预算耗尽的那个实例进入 `errored`，邻居不受影响。
- 重启后的实例重新监听同一个端口，重新加入端口组，重新走一遍探测。

连续异常重启的次数超过 `max_restarts` 后，该项目整体不会停，只有那个实例停下等人工介入。

## 端口规划

cluster 项目只占**一个**端口槽。

端口冲突检查按项目声明的范围算：cluster 是 `port`，fork 是 `port ~ port + instances - 1`。两段范围有交集就拒绝登记，并点名占着那段范围的项目。

```text
port conflict: web port range 3000~3000 overlaps api 3000~3003
```

因此同一个端口不能既给 cluster 项目又给 fork 项目。

`bm2 check` 会在启动前把这段范围逐个探测一遍，并说明每个端口是空闲、被共享监听者占着（能加入）、还是被独占监听者占着（不能加入）。

```text
config ok: project "api", 4 x cluster on port 3000, runtime bun
notify: disabled
ports 3000~3000: free
```

注意这里也会看到本项目自己的实例：对一个正在运行的项目跑 `bm2 check`，它占的端口当然不空闲。

## 网关怎么写

cluster 模式对网关只有一个要求：指到那个端口。

```nginx
upstream api {
    server 127.0.0.1:3000;
}

server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy 一行。

```text
api.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

实例增减不需要动网关。这是 cluster 相对 fork 最省事的地方。

网关的 `keepalive` 与后端的 `keep-alive` 会影响分发均匀度：长连接越少，内核分得越均匀。需要严格均分或按权重分发时，用 fork 模式把分发权交给网关。

## 应用里如何区分主实例

`BM2_APP_INSTANCE` 是实例编号，从 `"0"` 开始。cluster 模式下它同样可用，主实例仍然是 `0`。

```js
if (process.env.BM2_APP_INSTANCE === "0") {
  // 只在主实例执行：数据库迁移、定时任务等一次性逻辑
}
```

只跑一次的活放主实例是应用自己的约定，bm2 只负责把编号注入进去。

## 什么时候不要用 cluster

- 应用无法设置 `reusePort`（老代码、第三方服务、不归你改的程序）。
- 需要每个实例一个端口（按实例做健康检查、按实例分流、按实例限流）。
- 只监听回环地址。探测在 `0.0.0.0` 上做，应用只绑 `127.0.0.1` 时地址不匹配，可能被判为独占。
- 需要在网关侧按权重或按会话分发。

这几种情况用 [fork 模式](/guide/mode-fork)。

## 排障清单

`bm2 list` 里全部实例是 `errored`，执行模式列是 `cluster`。

1. 看 `~/.bm2/<项目名>/logs/<项目名>-0.crash.log`，`reason=reuseport_missing` 就是它。
2. 看 `~/.bm2/bm2d.events.jsonl` 里的 `reuseport_missing` 事件。
3. 检查应用是不是真的打开了 `reusePort`，而不是只在文档里写了。
4. 检查应用监听的是不是所有地址，而不是只绑回环。
5. 用 `bm2 check` 看端口当前是空闲、共享还是独占。

改完再 `bm2 serve`。

两种执行模式的完整对照见[负载均衡](/guide/load-balancing)，环境变量见[环境变量](/guide/environment)。
