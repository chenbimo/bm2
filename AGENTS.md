# AGENTS.md

bm2:用 MoonBit 编写的 Linux Bun 进程管理器(CLI `bm2` + 守护进程 `bm2d`)。

## 开发环境

- 仅 Linux(WSL Debian);要求内核 >= 5.3(pidfd)
- 工具链:moon(位于 `~/.moon/bin/moon`)、bun;仓库可放在 Windows 路径(如 `/mnt/c/codes/moonbit/bm2`),所有命令一律在 WSL 内执行
- Windows 侧自动化调用统一走 `wsl -d Debian --cd /mnt/c/codes/moonbit/bm2 -- bash <脚本>`,复杂命令先落盘成脚本再执行,不拼长命令行

## 统一检查入口

改动后必须完整跑:

```bash
bash scripts/verify.sh
```

内含 `moon fmt`、`moon check --target native --deny-warn`、`moon test --target native`、`moon build --target native` 与端到端验收(`scripts/e2e/run.sh`)。不要绕过入口直接调底层工具。

## 版本发布三处同步

发布时同步 `moon.mod` 的 `version` 与 `src/cmd/bm2/main.mbt` 的 `VERSION` 常量(verify.sh 强制校验),再发布 mooncakes。

## 代码结构

- `src/config` — bm2.toml 解析与校验(纯 MoonBit TOML 依赖)
- `src/core` — 实例状态机、监督循环、恢复/收养、协议、状态持久化
- `src/process` — 最小 POSIX FFI(`native.c`)+ MoonBit 封装
- `src/cmd/bm2`、`src/cmd/bm2d` — CLI 与守护进程入口

## 硬性约定

- Linux-only,不引入跨平台抽象层
- 配置不执行 shell 字符串;启动命令固定为参数数组
- 环境变量值不得写入状态文件、事件、crash 日志或 CLI 输出
- 状态文件一律原子写(经 `@process.write_atomic`)
