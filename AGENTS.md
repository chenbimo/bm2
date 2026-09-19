# AGENTS.md

bm2:用 MoonBit 编写的 Linux Bun 进程管理器(CLI `bm2` + 守护进程 `bm2d`)。

## 开发环境

- 仅 Linux(WSL Debian);要求内核 >= 5.3(pidfd)
- 工具链:moon(位于 `~/.moon/bin/moon`)、bun;仓库可放在 Windows 路径(如 `/mnt/c/codes/moonbit/bm2`),所有命令一律在 WSL 内执行
- Windows 侧只用于写代码(编辑器可能用更新版本的工具链做分析);**评审、检查、测试、构建、e2e 一律在 WSL 内进行**
- 构建目录按环境隔离:WSL 的脚本统一用 `--target-dir _build-wsl`,IDE/Windows 用默认 `_build`;两边工具链版本可能不同,共用同一目录会互相写坏缓存
- Windows 侧自动化调用统一走 `wsl -d Debian --cd /mnt/c/codes/moonbit/bm2 -- bash <脚本>`,复杂命令先落盘成脚本再执行,不拼长命令行

## 统一检查入口

改动后必须完整跑:

```bash
bash scripts/verify.sh
```

内含 `moon fmt`、`moon check --target native --deny-warn --warn-list +implicit_impl_as_method`、`moon test --target native`、`moon build --target native` 与端到端验收(`scripts/e2e/run.sh`)。不要绕过入口直接调底层工具。

那条 `--warn-list` 用来对齐 IDE 默认显示的弃用警告(隐式 trait 方法提升):IDE 侧的 Windows 工具链可能比这里钉的版本新,不显式开启就会漏掉。

## 提交门禁

`.githooks/` 是版本化的钩子,启用一次:

```bash
git config core.hooksPath .githooks
```

- `pre-commit` → `scripts/pre-commit.sh`:自动 `moon fmt` 并重新暂存格式化结果、校验版本号一致、跑上面那条 `moon check`。任何警告或错误都中断提交。
- `pre-push` → `scripts/verify.sh`:完整入口(含单测、构建与 e2e)。

工具链在 WSL 里,而 git 常在 Windows 侧调用,因此 `scripts/git-hook.sh` 负责派发:在 Windows 上提交时自动转入 WSL 执行同一个脚本。紧急情况用 `git commit --no-verify` / `git push --no-verify` 跳过。

## 版本发布三处同步

发布时同步 `moon.mod` 的 `version` 与 `src/cmd/bm2/main.mbt` 的 `VERSION` 常量(verify.sh 强制校验),再发布 mooncakes。

## 更新日志

遵循 `code-changelog` 技能(跨仓库通用规范,详见该技能),要点:

- 项目根目录一份 `CHANGELOG.md`;顶部 `# v.no.version` 哨兵块累积未发版改动,**人不写版本号、不写日期**
- 发版时把哨兵标题改成 `# v<版本> - <发布当天日期>`,并在文件顶部补回一块新的 `# v.no.version`
- 分类固定 `## 新增` / `## 优化` / `## 修复`(按需再用 `## 删除`),只保留非空分类
- **只记用户能感知的业务变化**:格式化、提交规范、构建/CI/发布脚本、文档与注释、纯测试、无感依赖升级、内部重构一律不记;写之前先自问"用户能感觉到吗"
- 不写 commit 摘要、文件路径、函数名;纯文案或错字的用户可见修正也要记一条
- 做完一项业务改动就往对应分类末尾追加一条,不要攒到发版时才补

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
