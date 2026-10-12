# bm2 仓库约定

Linux 下的 Bun / Node.js 进程管理器:CLI `bm2` + 守护进程 `bm2d`。单模块仓库,模块名 `chensuiyi/bm2`,依赖库作为模块内包平铺在 `src/`。

## 工具链

- MoonBit **以 WSL 里的版本为准**(当前 `moonc 0.10.15`);IDE 与 CI 跟随该版本
- **操作环境:除用 IDE 写代码外,构建 / 测试 / 验证 / 发包全部在 WSL 执行**(Windows 侧不装工具链、不发包)
- **构建目录两级制**:`_build` = Windows IDE 默认产物;`_build-wsl` = WSL 全部构建的显式目标(`--target-dir _build-wsl`)。两棵树隔离,防止 IDE 与 WSL 的缓存互相污染
- **WSL 互操作层不可信(已实证)**:本机 wsl.exe 的参数桥会随机损坏输出与退出码回传——同一二进制,interop 通道测得恒 0,文件通道测得真实码(2/1/0)。因此:复杂命令一律落盘脚本后以 `wsl bash 脚本` 执行;涉及退出码 / 输出内容的验证,**结果必须写文件再读回**,禁止依赖命令行回传;出现"异常退出码"类怪象时,先用文件通道复测再定位
- Windows 侧自动化调用统一走 `wsl -d Debian --cd /mnt/c/codes/moonbit/bm2 -- bash <脚本>`
- **产品文案**:面向全球开发者,CLI 帮助/输出/错误与通知文案统一英文,不做 i18n;README 用单文件内嵌双语;事件日志与状态文件保持语言中立键

## 目录结构

- `src/config` — bm2.toml 解析与校验(`[notify]` 订阅过滤也在此层)
- `src/core` — 实例状态机、监督循环、恢复/收养、协议、状态持久化、通知适配层
- `src/fsx` — 文件读写、原子写与锁(含 C 桩)
- `src/ipc` — CLI↔守护进程控制通道(长度前缀帧 + 子命令,经 loopback TCP + 共享令牌)
- `src/log` — 事件日志与按大小轮转
- `src/notify` — 通知子系统(多平台 webhook 与 SMTP)
- `src/proc` — 进程与系统调用(spawn / pidfd / procfs / 信号,含 C 桩)
- `src/util` — 纯函数工具(日期、文本与 JSON 辅助、版本比较)
- `src/cmd/bm2`、`src/cmd/bm2d` — CLI 与守护进程入口(参数解析用 core/argparse);版本常量在 `src/cmd/bm2/version.mbt`

按能力分包、按功能分文件;`src/util` 只放纯函数,有副作用的能力各自成包。命令 main 放 `src/cmd/<命令名>` 子包,二进制名与目录名一致。

## bm2d 监督循环(严格遵守)

- tick(50ms)内新增的周期性检查**必须自带时间闸**(参考 `check_notify` 的 `NOTIFY_CHECK_INTERVAL_MS` 模式):cron 分钟粒度检查用 60s 闸,重扫描用各自间隔闸;无闸的周期检查不予合入
- 到期/事件型检查(deadline/pending/removals 等)不加闸,但必须保证重复调用幂等
- 通知投递保持在 tick 内同步执行(上限 `timeout_ms`),不得挪为独立任务——supervisor 变更的单写者串行模型是正确性根基

## 测试粒度

验证分三档,由内向外升级,**禁止拿全量当快检**(每改一步跑一次全量是错误用法):

1. **快检**(改完即跑,秒级):`moon check <改动的包路径> --deny-warn --warn-list +implicit_impl_as_method --target-dir _build-wsl`
2. **模块测试**(功能完成时,十秒级):`moon test --target native`
3. **全量**(批次收尾一次):`bash scripts/verify.sh`(fmt / check / 单测 / 构建);交付或发布前加 `--with-e2e` 跑端到端

e2e 不拆段不过滤(全部用例共享守护进程与状态,拆分省不了多少还添脆弱);测试内的 sleep 是真实时序语义,不为速度压缩。

## 发布

发布(版本递增、构建产物、上传下载站、发 mooncakes)由 yicode-tech 仓库的 `scripts/famoonbit` 承担,本仓库不保留发布脚本。

版本号在发布时由 famoonbit 同步写入 `moon.mod` 与 CLI 的 `VERSION` 常量,两者必须一致(verify.sh 与 pre-commit 校验)。

## 提交格式(严格遵守)

```text
[项目名](类型) 提交内容
```

- **项目名**:代码与脚本用 `bm2`;仓库级配置(`.githooks`、`.github`、`README`、本文件、`LICENSE`)用 `root`
- **类型**:`feat` / `fix` / `docs` / `refactor` / `test` / `chore`
- **提交内容**:一句话说明,中文,结尾不加句号

示例:

```text
[bm2](feat) 新增 reload 命令
[root](docs) 补充单模块结构说明
```

Merge / Revert 提交豁免(git 生成首行,格式不适用)。提交格式由 `commit-msg` 钩子强制校验。

## Git Hooks

钩子位于根目录 `.githooks/`,跨环境分发:git 在 Windows 驱动时自动把检查交给 WSL 执行。

激活(仓库初始化后执行一次):

```bash
git init
git config core.hooksPath .githooks
```

| 钩子 | 时机 | 做什么 |
| --- | --- | --- |
| `commit-msg` | 提交时 | 强制校验上文提交格式,不合规则的提交被拒绝 |
| `pre-commit` | 提交时 | 仅当本次改动了 `src/` 或 `moon.mod` 时:`moon fmt` 自动修复并重新暂存 + `moon check --deny-warn` + 版本号一致校验 |
| `pre-push` | 推送时 | `bash scripts/verify.sh`(fmt / check / 单测 / 构建);e2e 由发布前手动跑 |

- 确需绕过:`git commit --no-verify`(例外应 rare)
- 钩子实现:`scripts/hook-dispatch.sh`(跨环境分发)+ `scripts/{pre-commit,commit-msg,pre-push}.sh` + `scripts/lib/{common,checks}.sh`

## 硬性约定

- 仅 Linux(内核 >= 5.3,pidfd),不引入跨平台抽象层
- 配置不执行 shell 字符串;启动命令固定为参数数组
- 环境变量值不得写入状态文件、事件、crash 日志或 CLI 输出
- 状态文件一律原子写(经 `@fsx.write_atomic`)
- 通知的端点与凭据(`url`/`secret`/`username`/`password`)不得进入事件、状态、日志与 CLI 输出;校验错误只报字段名与 `target[i]` 下标
- 通知投递失败只记事件,绝不改变监督行为
- 网络能力(HTTP/SMTP)由内联的 notify 库提供,bm2 内不自实现、不引入 curl
