# bm2

`bm2` 是一个现代化的 Bun 与 Node.js 进程管理器，基于 MoonBit 编写。

它由命令行工具与后台守护进程组成：命令行通过本机 TCP + 共享令牌下达指令，守护进程持续托管应用进程。每个用户一个守护进程，可同时管理多个项目。

- 两个原生静态二进制，无额外依赖，空闲守护进程约 `2.6 MB`
- 崩溃自动重启，带连续重启预算；预算耗尽即停下等你介入，而不是无限重试
- cluster 模式基于内核 `SO_REUSEPORT`，无中间层、无单点
- 守护进程崩溃后应用继续运行，新守护进程原地收养
- 内置日志轮转、按项目独立配置的通知上报、不停机自升级
- 配置是静态 TOML，字段强校验，不执行任何代码

反向代理与负载均衡交给 Nginx、Caddy 之类的网关，bm2 只专注进程托管。仅支持 Linux，需要内核 >= 5.3。

## 安装

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
moon install chensuiyi/bm2/...
```

`bm2` 与 `bm2d` 一起安装到 `~/.moon/bin`，无需配置 `PATH`。安装与升级的完整说明见[文档](docs/guide/install.md)。

## 快速开始

在项目目录创建 `bm2.toml`：

```toml
name = "api"
script = "src/index.ts"
instances = 2
port = 3000
```

```bash
bm2 serve        # 生产模式：登记并启动（读 .env 与 .env.production）
bm2 dev          # 开发模式：单实例，前台跟随日志
bm2 list         # 查看状态
bm2 stop api     # 停下,留在册
bm2 remove api   # 退役,交还名字(日志保留)
bm2 kill -y      # 停掉全部项目并退出守护进程
```

## 文档

完整手册在 `docs/` 下，可以直接读 Markdown，也可以在本地起站点：

```bash
cd docs && bun install && bun run dev
```

| 主题 | 位置 |
| --- | --- |
| 安装与升级 | [docs/guide/install.md](docs/guide/install.md) |
| 配置 | [docs/guide/configuration.md](docs/guide/configuration.md) |
| 环境变量 | [docs/guide/environment.md](docs/guide/environment.md) |
| 命令 | [docs/guide/commands.md](docs/guide/commands.md) |
| 负载均衡 | [docs/guide/load-balancing.md](docs/guide/load-balancing.md) |
| 状态与日志 | [docs/guide/state-and-logs.md](docs/guide/state-and-logs.md) |
| 通知与上报 | [docs/guide/notifications.md](docs/guide/notifications.md) |
| 功能特性 | [docs/guide/features.md](docs/guide/features.md) |

与 pm2 的完整对比表在文档首页：[docs/index.md](docs/index.md)。

文档目前只有中文。英文版等实现稳定之后再补——同时维护两份必然漂移，之前英文 README 的命令清单就落后过整整一代。
