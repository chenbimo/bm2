# 十五分钟上手

这一页从空目录开始，把一个小服务跑起来，再走完启动、观察、改配置、停止、退役的完整流程。

命令都在项目目录里执行。装好 bm2 之前先看[安装与升级](/guide/install)。

## 一、准备项目

新建一个目录，写两个文件。

```
my-api/
├── bm2.toml
└── index.ts
```

`bm2.toml` 是这份配置的全部。

```toml
name = "my-api"
script = "index.ts"
instances = 2
port = 3000
```

`index.ts` 是一个最小服务。

```ts
Bun.serve({
  port: Number(Bun.env.BM2_APP_PORT),
  reusePort: true,
  fetch(request) {
    return new Response(`instance ${Bun.env.BM2_INSTANCE_ID}`)
  },
})
```

三个细节值得先讲清。

端口不要写死，读 `BM2_APP_PORT`。bm2 会在启动每个实例时注入它，`fork` 模式下每个实例拿到的值不同。

`reusePort: true` 只在 `cluster` 模式下需要。默认就是 `cluster`，所以这份示例写了它。

`BM2_INSTANCE_ID` 是实例序号，从 `0` 开始，用来在响应里看出请求落到了哪个实例。

## 二、先校验配置

```bash
bm2 check
```

它只读当前目录的 `bm2.toml`，不碰守护进程。

字段写错、路径不对、端口越界、占位符变量没设置，都会在这里被指出来。

`bm2 serve` 执行的是同一套校验，所以这一步可以跳，但在部署前跑一次很值。

## 三、启动

```bash
bm2 serve
```

它做四件事：校验配置、登记项目、拉起守护进程、启动实例。

看到 `started` 之后，看看现状。

```bash
bm2 list
```

你会得到一张表。

```
│ 名称   │ 实例 │ PID   │ 端口 │ 模式 │ 执行   │ 状态   │ 次数 │ 内存  │ 运行时长 │ 目录          │
│ my-api │    0 │ 48213 │ 3000 │ 生产 │ 集群   │ online │ 1    │ 61 MB │ 8s       │ /srv/my-api   │
│ my-api │    1 │ 48214 │ 3000 │ 生产 │ 集群   │ online │ 1    │ 60 MB │ 8s       │ /srv/my-api   │
```

两个实例共用一个 `3000`，这是 `cluster` 模式的正常表现。

验证一下服务确实在响应。

```bash
curl http://127.0.0.1:3000
```

反复执行，返回的实例序号会变化，说明内核正在把连接分给两个实例。

## 四、看日志

日志在状态目录里，按项目分开。

```bash
ls ~/.bm2/my-api/logs/
```

三个文件按用途分开：`my-api-0.out.log` 是标准输出，`my-api-0.error.log` 是标准错误，`my-api-0.crash.log` 只记崩溃诊断。

跟随实时输出。

```bash
tail -f ~/.bm2/my-api/logs/my-api-0.out.log
```

日志超过 `[logs] max_size_mb` 会自动轮转，归档留在同目录，代数由 `keep` 决定。

## 五、改配置

改端口或者实例数，然后重新执行一次。

```bash
bm2 serve
```

每次 `bm2 serve` 都是一次完整重启，所以改动立刻生效。

它不会为了改一个数字而平滑迁移连接：那一刻旧实例退场，新实例起来，反代那边短暂 502 是正常的。要零停机改配置，先在另一份配置上把新版本跑起来，再切流量。

## 六、停下与恢复

```bash
bm2 stop my-api
```

实例全部退出，但项目和日志都还在册。

这个停止是持久的。守护进程重启、`bm2 reload` 都不会把它带回来。

```bash
bm2 serve
```

再执行一次，它就从停止状态恢复。

## 七、退役

```bash
bm2 remove my-api
```

项目注销，名字交还，日志保留。

日志保留是有意的：真正想翻日志的时刻，往往发生在项目消失之后。

连日志一起清掉。

```bash
bm2 remove my-api -f
```

名字被别的配置占用、旧目录没人管，这类残骸用 `bm2 clean` 扫。

```bash
bm2 clean --dry-run   # 只看不动
bm2 clean             # 真删
```

## 八、接反向代理

`cluster` 模式只有一个端口，网关写一条就行。

```nginx
upstream my_api {
    server 127.0.0.1:3000;
}

server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://my_api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

换成 `exec_mode = "fork"` 时端口从 `port` 开始连续分配，两个实例就是 `3000` 与 `3001`，upstream 要写两条。

两种模式的取舍与完整示例在[负载均衡](/guide/load-balancing)。

## 九、接告警

在 `bm2.toml` 里加一段，改完重新 `bm2 serve`。

```toml
[notify]
enabled = true
lang = "zh"
events = ["crash", "errored", "memory_limit", "reuseport_missing"]
threshold_rss_percent = 80

[[notify.report]]
name = "故障告警"
events = ["crash", "errored"]

[[notify.report.target]]
platform = "feishu"
url = "__BM2_FEISHU_WEBHOOK__"
```

真值放在项目目录的 `.env` 里，不写进配置。

```
BM2_FEISHU_WEBHOOK=https://open.feishu.cn/open-apis/bot/v2/hook/xxxx
```

先发一条测试消息，确认链路通。

```bash
bm2 notify
```

事件、阈值、周期报告的完整写法在[通知](/guide/notifications)。

## 十、升级与换班

```bash
bm2 upgrade
```

它比对版本、下载本平台的两个二进制、校验 SHA256、换入，再让新守护进程接管。应用全程继续运行。

只换了二进制、想手动换守护进程时：

```bash
bm2 reload
```

## 走到这里你已经会了

- 配置怎么写，校验怎么跑。
- 实例怎么起，状态怎么看。
- 日志在哪，轮转怎么配。
- 停止、恢复、退役、清理的分工。
- 网关怎么接，告警怎么发。
- 升级与换班。

日常会用到的只剩 `bm2 list` 与 `bm2 serve`。

出问题时翻[排障与常见问题](/guide/troubleshooting)。

## 上线前最后一遍

八条检查，每条都能在一分钟内确认。

1. `bm2 check` 通过，配置本身没有隐患。
2. 端口不与机器上其它服务冲突，`fork` 模式整段端口都要空着。
3. `cluster` 模式的应用已经开了 `reusePort`。
4. `max_memory_mb` 与机器内存匹配，`max_restarts` 不要设成很大的数字。
5. `[logs]` 给了明确的大小与代数，磁盘有上界。
6. `[notify]` 的凭据走 `__NAME__` 占位符，真值在 `.env` 里，没有进仓库。
7. `bm2 notify` 能收到测试消息。
8. 网关的 upstream 指向正确的端口，`cluster` 一条，`fork` 每个实例一条。

再加一条运行面的：真正重启一次机器，确认项目能自己回来。bm2 不管开机自启，靠 systemd 或你的启动脚本。
