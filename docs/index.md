---
layout: home

hero:
  name: bm2
  text: Bun 与 Node.js 的进程管理器
  tagline: 两个静态二进制，自身不带运行时。监督、日志轮转、通知与自升级，全由一个守护进程完成。
  actions:
    - theme: brand
      text: 十五分钟上手
      link: /guide/quickstart
    - theme: alt
      text: 命令参考
      link: /guide/commands

features:
  - title: 崩了自己会起来
    details: 异常退出按延迟重启，连续重启超过预算就停下等人工介入，不会无限重试掩盖真问题。
  - title: 守护进程崩了应用不断
    details: 应用继续运行，新守护进程用 pidfd 认出原进程，校验环境后原地接管。
  - title: 两套多实例方案
    details: fork 用连续端口交给网关，cluster 共用一个端口由内核分发，没有中间层也没有单点。
  - title: 日志与上报都内置
    details: 按大小轮转、按项目配置代数。飞书、钉钉、企业微信、Slack、Discord、webhook、邮件开箱可用。
---

## 一张图看懂它怎么运转

<div style="overflow-x:auto;margin:12px 0 4px">
  <img src="/bm2-flow.svg" alt="bm2 架构与执行流程：外部请求经 Nginx 或 Caddy 进入，bm2 命令交给守护进程，守护进程拉起并监督应用实例，实例支持 cluster 共享端口与 fork 连续端口两种模式，日志落盘并推送事件" width="1240" height="620" style="min-width:1040px;width:100%;height:auto;display:block">
</div>

左半部分是控制面：你敲命令，守护进程负责拉起与监督。指令不进业务链路，业务挂了才需要它出手。

右半部分是数据面：外部请求先到 Nginx 或 Caddy，再按模式打到实例端口。网关只管域名、TLS 与分发，进程死活归 bm2。

中间两张卡是同一种东西的两种排布。`cluster` 让所有实例共用 `3000`，由内核按连接分发，网关写一条 upstream 就够。`fork` 把端口连续排开，网关按实例逐条写 upstream。

下面两条是记录与告警：日志按大小轮转落盘，事件经去重限流之后推到你配的群或邮箱。

图里的六步是六个动作：`bm2 serve` 登记并启动、守护进程监督实例、网关把请求打到端口、崩溃后自动重启、日志落盘、事件上报。

## 为什么还要再造一个进程管理器

把一个 Bun 或 Node.js 服务放在 Linux 上长期运行，最常见的做法是 `pm2`。

它解决了很多问题，也带来几个新的。

`pm2` 自己就是一个 Node.js 应用，于是想管 Bun 项目，得先装 Node.js。

它的 cluster 模式有一个 master 进程负责分发连接，master 挂了，整个应用跟着断。

它的日志轮转要靠额外的模块，配置写在可执行的 `ecosystem.config.js` 里，部署即执行代码。

bm2 的选择是把这件事做成两个原生静态二进制：命令行 `bm2` 与守护进程 `bm2d`。

没有运行时依赖，没有中间分发层，没有要额外安装的插件，配置是逐字段校验的静态 TOML。

## 它解决的四类问题

**第一类：应用挂了没人管。**
bm2 自动重启，但设了连续重启预算。预算耗尽进入 `errored` 状态并停下自愈，因为不停重试只会掩盖真实故障。

**第二类：守护进程自己挂了。**
应用不会跟着死。新守护进程接管原进程，PID 不变，连接不断。

**第三类：日志把磁盘写满。**
stdout、stderr 与崩溃诊断分三路落盘，超过设定大小即轮转，代数可配。

**第四类：出了问题你是最后一个知道的。**
崩溃、预算耗尽、内存超限、启动超时、离线过久、重启过频、磁盘吃紧都可以推到群里或邮箱，还能定时收体检报告。

## 它不做什么

这点比能力清单更值得先看。

bm2 只做进程托管。反向代理、TLS、域名交给 Nginx 或 Caddy。开机自启交给 systemd。远程运维、集群编排、容器调度不在范围内。

需要这些能力时它们和 bm2 并排用，互不冲突。

## bm2 与 pm2 对比

| 对比项 | bm2 | pm2 |
| --- | --- | --- |
| 形态 | 原生静态二进制 | Node.js 应用 |
| 额外依赖 | 无 | Node.js 运行时 |
| 体积 | 约 `5.5 MB`（两个二进制） | 约 `23 MB` |
| 文件数量 | `2` 个 | `3036` 个 |
| 空闲守护进程内存 | 约 `2.6 MB` | 约 `50 MB` |
| 命令响应 | 约 `1 ms` | 约 `200~400 ms` |
| 日志轮转 | 内置 | 需额外安装 `pm2-logrotate` 模块 |
| 多实例模式 | `fork` 连续端口 + `cluster` 单端口（内核分发） | `fork` + `cluster`（master 分发） |
| cluster 分发层 | 内核 `SO_REUSEPORT`，无中间层、无单点 | cluster master 进程，宕机即整应用中断 |
| 守护进程崩溃 | 应用无感继续运行，新守护进程原地收养 | cluster 应用随之中断，恢复需重建进程树 |
| 配置方式 | 静态 TOML，字段强校验，零代码执行 | `ecosystem.config.js`，可执行任意代码 |
| 环境变量 | 最小白名单 + 保留变量显式注入 | 继承调用 shell 的完整环境 |
| 崩溃恢复 | pidfd 钉住原进程收养，环境校验防误管 | 守护进程崩溃后按 dump 重建，不收养 |
| 自升级 | `bm2 upgrade`：比对版本、下载校验、自动换入新守护进程 | npm 手动升级后 `pm2 update` 重载 |

已经在用 pm2 的话，[从 pm2 迁移](/guide/migration-from-pm2)那页有逐条的对应关系与改法。

## 从哪里开始

- 第一次用：读[十五分钟上手](/guide/quickstart)，从空目录走到正在服务的实例。
- 要写配置：读[配置](/guide/configuration)，字段、默认值、约束与占位符都在那里。
- 要接网关：读[负载均衡](/guide/load-balancing)，`cluster` 与 `fork` 的差别决定了网关怎么写。
- 要接告警：读[通知](/guide/notifications)，事件、阈值、周期报告的完整写法。
- 出问题了：先翻[排障与常见问题](/guide/troubleshooting)。
