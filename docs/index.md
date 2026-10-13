---
layout: home

hero:
  name: bm2
  text: Bun 与 Node.js 的进程管理器
  tagline: 两个静态二进制，自身不带运行时。监督、日志轮转、通知与自升级，全部由一个守护进程完成。
  actions:
    - theme: brand
      text: 开始使用
      link: /guide/install

---

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

## 它不管理什么

反向代理、域名、证书、热重载、开机自启与远程管理都交给别的工具。bm2 只做进程托管，需要域名、TLS 或跨机分发时，配一个 Nginx 或 Caddy 即可——cluster 模式下网关只需要一条 upstream。
