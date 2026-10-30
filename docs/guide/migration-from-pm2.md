# 从 pm2 迁移

这一页给已经用 pm2 的项目一条明确的迁移路径。

结论先说：迁移成本主要在配置和环境变量两处，命令层几乎是一一对应。

## 命令对照

| 你要做的事 | pm2 | bm2 |
| --- | --- | --- |
| 启动（生产） | `pm2 start ecosystem.config.js` | 在项目目录 `bm2 serve` |
| 启动（开发） | `pm2 start app.js --watch` | `bm2 dev` |
| 查看列表 | `pm2 list` | `bm2 list` |
| 查看某个项目 | `pm2 describe api` | `bm2 list api` |
| 看实时日志 | `pm2 logs api` | `tail -f ~/.bm2/api/logs/api-0.out.log` |
| 停止 | `pm2 stop api` | `bm2 stop api` |
| 重启 | `pm2 restart api` | `bm2 serve` |
| 删除 | `pm2 delete api` | `bm2 remove api` |
| 清空日志 | `pm2 flush` | 按轮转策略自动处理，或手工删 `logs/` 下的文件 |
| 开机自启 | `pm2 startup` + `pm2 save` | 交给 systemd，见下文 |

## 配置对照

pm2 的 `ecosystem.config.js` 与 bm2 的 `bm2.toml` 是一一对应的，只是从可执行代码换成了静态数据。

| pm2 字段 | bm2 字段 | 说明 |
| --- | --- | --- |
| `name` | `name` | 项目名，同时是状态目录名 |
| `script` | `script` | 相对 `cwd` 的路径，禁止 `..` |
| `cwd` | `cwd` | 绝对路径 |
| `instances` | `instances` | 1 到 1024 |
| `exec_mode` | `exec_mode` | `cluster` 或 `fork` |
| `env` | `.env` 文件 | 不再写在配置里 |
| `max_memory_restart` | `max_memory_mb` | 单位是 MiB |
| `restart_delay` | `restart_delay_ms` | 毫秒 |
| `max_restarts` | `max_restarts` | 连续异常重启预算 |
| `min_uptime` | `min_uptime_ms` | 短于此命数的干净退出也计入预算 |
| `kill_timeout` | `stop_timeout_ms` | `SIGTERM` 到 `SIGKILL` 的宽限期 |
| `log_file` / `error_file` | 不需要配 | 日志固定落在状态目录 |
| `autorestart` | 不需要配 | 崩溃自动重启是默认行为 |

## 三个必须知道的差异

**第一，每次启动都是完整重启。**

pm2 的 `pm2 reload` 能做零停机重载。bm2 没有这个模式：`bm2 reload` 换的是守护进程，不是应用。

应用层改配置就是 `bm2 serve`，那一刻旧实例退场、新实例起来。

要零停机发布，做法是在另一份配置上把新版本跑在别的端口，切完流量再退役旧的。这不是 bm2 的短板，是它把「零停机」明确交给网关和发布流程去解决。

**第二，环境变量不再继承 shell。**

pm2 会把启动它的那套环境整个传给应用，于是「本地能跑、线上不行」经常因为环境不同。

bm2 只传白名单里的 `PATH`、`HOME`、`TMPDIR`、启动 `bm2` 时已有的 `BM2_*` 变量，加上项目自己 `.env` 文件里扫描出来的变量，再加上保留变量。

好处是同一份配置在哪跑都一样，代价是依赖 shell 里临时 `export` 的东西必须写进 `.env`，或者以 `BM2_` 开头导出。

**第三，端口由 bm2 注入。**

应用要读 `BM2_APP_PORT`，不要写死端口。

`cluster` 模式下所有实例拿到同一个值，`fork` 模式下从 `port` 开始连续分配。

## 迁移步骤

第一步，在旧项目上确认它现在占的端口和实例数。

```bash
pm2 describe api
```

第二步，在项目目录写 `bm2.toml`。

```toml
name = "api"
script = "index.js"
instances = 2
port = 3000
max_memory_mb = 512
max_restarts = 10
stop_timeout_ms = 10000

[logs]
max_size_mb = 10
keep = 7

[notify]
enabled = true
lang = "zh"
events = ["crash", "errored", "memory_limit", "reuseport_missing"]

[[notify.report]]
name = "故障告警"
events = ["crash", "errored"]

[[notify.report.target]]
platform = "feishu"
url = "__BM2_FEISHU_WEBHOOK__"
```

第三步，把原来的环境变量搬进 `.env` 文件。

```
DATABASE_URL=postgres://...
REDIS_URL=redis://...
```

`serve` 读 `.env` 与 `.env.production`，`dev` 读 `.env` 与 `.env.development`，`.local` 后缀的优先级更高。

第四步，校验配置。

```bash
bm2 check
```

第五步，先停掉 pm2 那边的实例，避免端口打架。

```bash
pm2 stop api
```

第六步，启动。

```bash
bm2 serve
bm2 list
```

用 `curl` 确认服务真的在响应，再继续。

第七步，确认无误后清掉 pm2 的记录。

```bash
pm2 delete api
pm2 save
```

## 开机自启交给 systemd

bm2 不负责开机自启，按 Linux 的惯例交给 systemd。

用 systemd 的用户级单元跑一次 `bm2 serve` 即可，项目起来之后由守护进程接管。

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

`ExecStart` 的路径按实际安装位置写。`moon install` 装到 `~/.moon/bin`，放在别处就改成别处的路径。

```bash
systemctl --user daemon-reload
systemctl --user enable --now bm2-api
loginctl enable-linger $USER
```

`enable-linger` 让服务在用户没有登录时也保持运行。

多个项目就写多个单元，各自指向自己的目录。

## 回滚

迁移期间想退回去，两步。

```bash
bm2 stop api
pm2 start ecosystem.config.js
```

确认新方案稳定之后，再 `bm2 remove api` 把登记清掉。

日志留在 `~/.bm2/api/logs/`，退役不会删它，需要时还能翻。

## 迁移后值得再确认的四件事

- 应用读的是 `BM2_APP_PORT`，不是写死的端口。
- `cluster` 模式开了 `reusePort`。
- 需要的环境变量都在 `.env` 里，能在一台干净机器上跑起来。
- 网关的 upstream 与新端口一致，`fork` 模式下有几条就写几条。

更细的配置说明见[配置](/guide/configuration)，端口与网关见[负载均衡](/guide/load-balancing)。
