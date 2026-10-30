# 负载均衡：两种模式怎么选

bm2 提供两种多实例方式。它们在「端口怎么分配」和「谁来分发」上完全不同，其余部分——配置字段、重启策略、日志、通知——一模一样。

| 对比项 | `cluster`（默认） | `fork` |
| --- | --- | --- |
| 端口 | 全部实例共用 `port` | `port` 起连续分配，`instances` 个 |
| 分发者 | 内核（`SO_REUSEPORT`） | 网关 |
| 应用侧要求 | 监听必须开 `reusePort` | 无，普通监听即可 |
| bm2 的检查 | 启动后实测端口能否加入，缺 `reusePort` 就停下整个项目 | 不检查 |
| 端口槽 | 1 个 | `instances` 个 |
| 网关写法 | 一条 upstream | 每个实例一条 upstream |
| 改实例数 | 不用动网关 | 必须同步 upstream 并 reload 网关 |
| 分发单位 | 新连接（keep-alive 粘在同一实例） | 由网关决定，可按权重、会话、健康状态 |
| 应用只绑 `127.0.0.1` | 探测在 `0.0.0.0` 上做，可能被判为独占 | 支持 |

两页专文把细节说全：[cluster 模式](/guide/mode-cluster)、[fork 模式](/guide/mode-fork)。

## 先看结论

- 应用能开 `reusePort`、实例无状态、希望网关简单：用 `cluster`。
- 应用改不了、需要每实例独立端口、需要网关侧分发规则：用 `fork`。
- 拿不准又只有一台机器：先 `fork`，它不要求应用配合，代价只是网关多写几行。

## 分发层的差别

**cluster 没有分发进程。** 每个实例自己监听同一个端口，内核按连接四元组哈希选一个 socket。因此不存在「分发层挂掉整站断掉」，也不存在分发层的额外一跳。

代价是控制权在网关之外：你无法按权重分流，也无法让某个实例多接。请求的落点由内核哈希与连接复用决定，长连接越多，越不均匀。

**fork 把分发权完整交给网关。** 每个实例一条独立后端，网关可以加权、可以做会话保持、可以按健康检查摘除。代价是网关配置跟着实例数走。

## 两种模式共用的部分

无论选哪种，下面这些都是一样的。

- 端口从 `BM2_APP_PORT` 读，`port` 只在 `bm2.toml` 里写一次。
- `BM2_INSTANCE_ID` 与 `BM2_APP_INSTANCE` 从 `"0"` 开始，主实例判断不变。
- 实例之间互相独立重启，重启预算按实例计。
- 一次 `bm2 serve` 是所有实例的完整重启，不是滚动更新。
- 日志、轮转、事件、通知按项目走，与模式无关。

## 网关示例

cluster 只需要一条。

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

fork 要一条一条写全。

```nginx
upstream api {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
    keepalive 32;
}

server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://api;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_next_upstream error timeout http_502;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy 两种模式各一行。

```text
# cluster
api.example.com {
    reverse_proxy 127.0.0.1:3000
}

# fork
api.example.com {
    reverse_proxy 127.0.0.1:3000 127.0.0.1:3001 127.0.0.1:3002
}
```

需要域名与 TLS 时两种模式都要配网关。bm2 不管证书，也不管域名解析。

## 同一个守护进程里混用

不同项目可以各选各的模式，只要端口范围不重叠。

```toml
# ~/srv/api/bm2.toml
name = "api"
exec_mode = "cluster"
instances = 4
port = 3000
```

```toml
# ~/srv/legacy/bm2.toml
name = "legacy"
exec_mode = "fork"
instances = 2
port = 4000
```

`api` 占 `3000` 一个槽，`legacy` 占 `4000 ~ 4001`。冲突检查按声明范围算，报名时就会指出重叠。

## 换模式要做什么

`exec_mode` 属于启动期参数，换它必须重新 `bm2 serve`。

同时做两件事：

1. cluster 换成 fork：网关从一条 upstream 改成每条实例一条，并且应用可以去掉 `reusePort`（留着也无害）。
2. fork 换成 cluster：应用必须打开 `reusePort`，网关改成一条 upstream，端口范围只保留起始端口。

从 fork 换成 cluster 前，先确认应用真的能开 `reusePort`。没开的话 `bm2 serve` 会成功、实例会短暂在线，然后在探测命中后整体进入 `errored`。

## 发布与流量切换

两种模式都不提供零停机重载。要做到不断服，在 bm2 之外解决。

- fork：新版本用另一段端口跑起来，改网关指向新的一组，确认无误后 `bm2 remove` 旧项目。
- cluster：新版本用另一个端口跑起来，网关改指向新端口，再退役旧的。

两种做法都需要两份配置、两个项目名与两段端口。bm2 只保证每个项目被稳定托管，切流量是网关与发布流程的事。

## 相关页面

- 端口、`reusePort` 探测与失败处理：[cluster 模式](/guide/mode-cluster)
- 连续端口、网关同步与应用写法：[fork 模式](/guide/mode-fork)
- 端口冲突与 `reuseport_missing` 的排查：[排障与常见问题](/guide/troubleshooting)
