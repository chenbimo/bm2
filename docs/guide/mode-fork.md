# fork 模式：端口连续分配，网关分发

`exec_mode = "fork"` 时，每个实例拿到自己的端口，从 `port` 开始连续分配。

`port = 3000`、`instances = 3` 时三个实例分别监听 `3000`、`3001`、`3002`。

```toml
name = "api"
script = "src/index.ts"
exec_mode = "fork"
instances = 3
port = 3000
```

分发不在 bm2 这一层，而在网关：Nginx、Caddy 或云负载均衡把请求分到这几条后端上。

## 它怎么工作

bm2 只做两件事：给每个实例算好端口，把端口注入进它的环境。

| 实例 | `BM2_APP_PORT` | `BM2_INSTANCE_ID` |
| --- | --- | --- |
| 0 | `3000` | `"0"` |
| 1 | `3001` | `"1"` |
| 2 | `3002` | `"2"` |

端口由实例编号决定，所以同一个实例每次重启都回到自己的端口，顺序不会漂。

应用侧只读 `BM2_APP_PORT`，不需要 `reusePort`。每个实例都是一个普通的独占监听者。

```js
const port = Number(process.env.BM2_APP_PORT)
http.createServer((req, res) => res.end("ok")).listen(port)
```

fork 模式下 bm2 不做 reusePort 探测，也不会因为没开 `reusePort` 停下项目。

## 为什么它是默认之外的那个选择

三条实际好处。

**应用不用改。** 任何能监听端口的程序都能跑，包括不归你维护的、没法加 `reusePort` 的。

**可以只绑回环。** 应用写 `listen(port, "127.0.0.1")` 就只对本机开放，网关在同一台机器上就能分发。cluster 模式的探测在 `0.0.0.0` 上做，应用只绑回环时地址不匹配，可能被判为独占，fork 没有这个问题。

**分发规则交给网关。** 按权重、按会话、按实例健康状态分流，都在网关侧表达，bm2 不干预。

代价同样明确：端口要规划，网关要跟着实例数一起改。

## 端口规划

fork 项目占 `instances` 个端口槽。`port = 3000`、`instances = 3` 就是 `3000 ~ 3002`。

- 整段必须落在 `1 ~ 65535` 内，所以 `port + instances - 1` 不能超过 `65535`。
- 不同在册项目的端口范围不能重叠，cluster 项目只算一个槽。
- 同一台机器上其它服务（数据库、网关本身）也要一起避开。

`bm2 check` 会把整段逐个探测并逐行报出结果。

```text
config ok: project "api", 3 x fork on port 3000, runtime bun
notify: disabled
ports 3000~3002: free
```

被占用时按端口逐条说明，并区分共享监听者与独占监听者。

```text
port 3001: already held by an exclusive listener
```

改实例数就会改端口范围：从 3 个改成 2 个，`3002` 释放出来，剩下两个不变。顺序保持稳定正是「端口由编号决定」的价值。

## 网关必须同步

这是 fork 模式要求你承担的那部分工作：**实例增减之后，upstream 列表要一起改，然后 reload 网关。**

Nginx。

```nginx
upstream api {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
}

server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://api;
        proxy_next_upstream error timeout http_502;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy。

```text
api.example.com {
    reverse_proxy 127.0.0.1:3000 127.0.0.1:3001 127.0.0.1:3002
}
```

网关不知道 bm2 的配置。它只认你写下的那几条后端，所以「配置改了但网关没改」是 fork 模式最常见的事故：实例起来了，流量还只打到旧端口，新实例闲着。

做发布时按顺序来：先改 `bm2.toml` 与 `bm2 serve`，再改 upstream 并 reload 网关。

## 停机与重启在网关侧的表现

一个实例被重启时，它那一行后端短暂不可用。

- 网关的被动健康检查（`proxy_next_upstream`、失败重试）能把这个空窗盖住。
- 主动健康检查需要应用提供一个可判定的健康端点，由网关定期探活。
- bm2 不向网关注册、也不摘除后端，它只保证实例在自己的端口上起来。

`bm2 serve` 是一次完整重启：所有实例先停再起，那几秒里所有后端同时不可用，网关会返回 `502`。需要零停机发布时，把新版本跑在另一段端口上，改网关指向新的一组，再退役旧的。

## 优雅停止

`bm2 stop` 对每个实例先发 `SIGTERM`，超过 `stop_timeout_ms` 再 `SIGKILL`。

要做连接排空的应用自己处理 `SIGTERM`：停止接受新连接、把进行中的请求处理完、然后退出。网关侧要能容忍一条后端在排空期间拒绝新连接。

## 应用里如何区分实例

`BM2_INSTANCE_ID` 与 `BM2_APP_INSTANCE` 都是实例编号，从 `"0"` 开始。fork 模式下每个实例的值不同，这正好可以做按实例的行为。

```js
const id = process.env.BM2_APP_INSTANCE
if (id === "0") {
  // 只在 0 号实例执行：一次性迁移、定时任务
}
```

`bm2 dev` 只跑一个实例，此时编号恒为 `"0"`，端口就是配置里的 `port`——不会有端口连续分配这回事。

## 什么时候该换成 cluster

- 应用能开 `reusePort`，而且实例完全无状态、可互换。
- 不想维护 upstream 列表，也不希望改实例数时还要动网关。
- 想少一层端口：一个端口对外，其余全在进程内。

这几种情况用 [cluster 模式](/guide/mode-cluster)。

## 排障清单

**端口冲突。** 报错会点名范围与占用者。

```text
port conflict: api port range 3000~3002 overlaps web 3001~3001
```

三种改法：换起始端口、减实例数、先退役占着那段范围的项目。

**实例在线但访问不到。** 先看 `bm2 list` 里每个实例的端口，再核对网关 upstream 是否逐个覆盖。少写一条的表现是「一部分请求 502」或「新实例完全没流量」。

**改完实例数没生效。** `bm2 reload` 只换守护进程，不重读项目配置。改实例数必须重新 `bm2 serve`，然后 reload 网关。

**只有 `3000` 能通。** 应用里写死了端口，没有读 `BM2_APP_PORT`。写死时三个实例都会去抢 `3000`，只有一个能起来。

两种模式的取舍与网关细节见[负载均衡](/guide/load-balancing)。
