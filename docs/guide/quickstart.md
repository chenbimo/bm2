# 十五分钟上手

这一页从空目录开始：写一份配置，把服务跑起来，改一次配置，再停下与退役。

命令都在项目目录里执行。装好 bm2 之前先看[安装与升级 bm2](/guide/install)。

## 一、准备项目

新建一个目录，写两个文件。

```text
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
const port = Number(process.env.BM2_APP_PORT)

Bun.serve({
  port,
  reusePort: true,
  fetch() {
    return new Response(
      `instance ${process.env.BM2_APP_INSTANCE} in ${process.env.NODE_ENV}`,
    )
  },
})
```

四个细节值得先讲清。

- 端口不要写死，读 `BM2_APP_PORT`。fork 模式下每个实例拿到的值不同。
- `reusePort: true` 只在默认的 `cluster` 模式下需要。
- `BM2_APP_INSTANCE` 是实例编号，从 `0` 开始，用它看请求落到了哪个实例。
- `NODE_ENV` 由启动动词决定：`serve` 给 `production`，`dev` 给 `development`。

## 二、先校验配置

```bash
bm2 check
```

它只读当前目录的 `bm2.toml`，不碰守护进程，也不登记任何东西。

字段写错、脚本不存在、端口越界、占位符变量没设置，都会在这里被指出来。它还会探测整段端口，告诉你端口是空闲还是已被占用。

`bm2 serve` 执行同一套校验，所以这一步可以跳过，但部署前跑一次很值。

## 三、启动

```bash
bm2 serve
```

它做四件事：校验配置、探测运行时、登记项目、拉起实例。

看到 `已启动` 之后，看看现状。

```bash
bm2 list
```

先是一行守护进程摘要，然后是实例表（英文环境下的形状）。

```text
api: starting
api: online
started
┌────────┬────┬───────┬──────┬────────────┬─────────┬────────┬───────┬────────┬─────────┬─────────────┐
│ NAME   │ ID │ PID   │ PORT │ MODE       │ EXEC    │ STATUS │ TIMES │ MEMORY │ UPTIME  │ CWD         │
├────────┼────┼───────┼──────┼────────────┼─────────┼────────┼───────┼────────┼─────────┼─────────────┤
│ my-api │  0 │ 48213 │ 3000 │ production │ cluster │ online │     1 │ 61 MB  │ 8s      │ /srv/my-api │
│ my-api │  1 │ 48214 │ 3000 │ production │ cluster │ online │     1 │ 60 MB  │ 8s      │ /srv/my-api │
└────────┴────┴───────┴──────┴────────────┴─────────┴────────┴───────┴────────┴─────────┴─────────────┘
```

表头与文案跟随项目语言。`BM2_LANG=en` 可以固定成上面这一份。

两个实例共用一个 `3000`，`cluster` 模式的正常表现。

验证服务确实在响应。

```bash
curl http://127.0.0.1:3000
```

反复执行，返回的实例编号会变化，说明内核正在把新连接分给两个实例。同一个 keep-alive 连接上的后续请求仍然落在同一个实例，这是 cluster 模式的分发单位。

## 四、看日志

日志在状态目录里，按项目分开。

```bash
ls ~/.bm2/my-api/logs/
```

```text
my-api-0.out.log
my-api-0.error.log
my-api-0.crash.log
```

三份按用途分开：标准输出、标准错误、崩溃诊断。跟随实时输出。

```bash
tail -f ~/.bm2/my-api/logs/my-api-0.out.log
```

日志超过 `[logs] max_size_mb`（默认 10 MiB）会自动轮转，归档留在同目录，代数由 `keep` 决定。

## 五、改配置

改端口或实例数，再执行一次。

```bash
bm2 serve
```

每次 `serve` 都是一次完整重启：旧实例全部停下，新实例按新配置起来。那一刻反代短暂 `502` 是正常的。

要零停机改配置，做法是在另一段端口上把新版本跑起来，切完流量再退役旧项目。这件事 bm2 不代劳。

## 六、停下与恢复

```bash
bm2 stop my-api
```

实例全部退出，但项目与日志都留在册。`bm2 list` 仍然能看到它，状态是 `stopped`。

这个停止是持久的：守护进程重启、`bm2 reload`、机器重启都不会把它带回来。

```bash
bm2 serve
```

再执行一次，它就从停止状态恢复。

## 七、退役

```bash
bm2 remove my-api
```

项目注销，名字交还，日志保留。真正想翻日志的时刻，往往发生在项目消失之后。

连日志一起清掉。

```bash
bm2 remove my-api -f
```

退役之后名字可以重新登记。手动删目录、或从别的机器拷过来的残留，用 `clean` 扫。

```bash
bm2 clean --dry-run   # 只看不动
bm2 clean             # 真删
```

## 八、接反向代理

`cluster` 模式只有一个端口，网关写一条就够。

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

换成 `exec_mode = "fork"` 时端口从 `port` 起连续分配：两个实例是 `3000` 与 `3001`，upstream 要写两条，而且以后改实例数还得同步改网关。

两种模式的区别与取舍：[cluster 模式](/guide/mode-cluster)、[fork 模式](/guide/mode-fork)、[怎么选](/guide/load-balancing)。

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

真值放在项目目录的 `.env.production` 里，不写进配置。

```text
BM2_FEISHU_WEBHOOK=https://open.feishu.cn/open-apis/bot/v2/hook/xxxx
```

先发一条测试消息，确认链路通。

```bash
bm2 notify
```

事件、阈值、周期报告的完整写法在[通知](/guide/notifications)。

## 十、升级 bm2 与换班

```bash
bm2 upgrade
```

它查最新版本、用 `moon install` 换入两个二进制，再让新守护进程接管。应用全程继续运行。

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

日常用得最多的是 `bm2 list` 与 `bm2 serve`。

出问题时翻[排障与常见问题](/guide/troubleshooting)。

## 上线前的九条

1. `bm2 check` 通过，配置与端口都没有隐患。
2. `cluster` 模式的应用已经开了 `reusePort`，并且监听所有地址而不是只绑回环。
3. `fork` 模式整段端口都空着，网关 upstream 逐个覆盖。
4. `max_memory_mb` 与机器内存匹配，`max_restarts` 不要设成很大的数字。
5. `[logs]` 给了明确的大小与代数，磁盘有上界。
6. `[notify]` 的凭据走 `__NAME__` 占位符，真值在 `.env` 里，没有进仓库。
7. `bm2 notify` 能收到测试消息。
8. 网关指向正确的端口：`cluster` 一条，`fork` 每个实例一条。
9. **开机自启已经配好。** bm2 不管自启，守护进程启动时也不会把项目拉起来，所以必须有一个 systemd 单元（或等价机制）在开机后执行 `bm2 serve`。

第九条最容易被忘：手工试的时候一切正常，重启一次机器后所有项目都不在了。
