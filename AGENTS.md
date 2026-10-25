# bm2 仓库约定

Linux 下的 Bun / Node.js 进程管理器:CLI `bm2` + 守护进程 `bm2d`。单模块仓库,模块名 `chensuiyi/bm2`,依赖库作为模块内包平铺在 `src/`。

## 工具链

- MoonBit **以 WSL 里的版本为准**(当前 `moonc 0.10.17`);IDE 与 CI 跟随该版本
- **操作环境:除用 IDE 写代码外,构建 / 测试 / 验证 / 发包全部在 WSL 执行**(Windows 侧不装工具链、不发包)
- **构建目录两级制**:`_build` = Windows IDE 默认产物;`_build-wsl` = WSL 全部构建的显式目标(`--target-dir _build-wsl`)。两棵树隔离,防止 IDE 与 WSL 的缓存互相污染
- **WSL 互操作层不可信(已实证)**:本机 wsl.exe 的参数桥会随机损坏输出与退出码回传——同一二进制,interop 通道测得恒 0,文件通道测得真实码(2/1/0)。因此:复杂命令一律落盘脚本后以 `wsl bash 脚本` 执行;涉及退出码 / 输出内容的验证,**结果必须写文件再读回**,禁止依赖命令行回传;出现"异常退出码"类怪象时,先用文件通道复测再定位
- Windows 侧自动化调用统一走 `wsl -d Debian --cd /mnt/c/codes/moonbit/bm2 -- bash <脚本>`
- **例外:文档站的 node 工具链跑在 Windows 侧**(`docs/` 下 `bun install` / `bun run dev`):Rollup 与 esbuild 装的是平台专属的原生二进制,`node_modules` 在 Windows 与 WSL 之间不可共用;而文档的交互(浏览器预览)发生在 Windows,工具链就该跟着交互走
- **产品文案**:人类可读的全部文案集中在 `src/i18n` 文案包,每条消息一个函数、按 `Lang` match,漏一种语言编译不过;加语言时编译器与测试全路带路,不允许任何一处静默回落
- **语言来源三层**:配置 `lang` 是声明,写不支持的值直接报错;环境与请求里不认识的值退回英文。归属规则:关于某个项目的消息跟项目配置走,全量表、帮助、升级这类跟操作者环境走
- **机器读的输出钉住语言**:门禁(`scripts/verify.sh`)固定 `BM2_LANG=en`,按列位解析的表格、e2e 的断言不能被宿主语言改写;人在命令行用 `BM2_LANG` 覆盖
- **终端表格交给 `chensuiyi/clitable` 渲染**:显示宽度(CJK 占两列)由它依赖的 `moonbit-community/unicodewidth` 负责,项目内不再手写 Unicode 宽度表;实例表与守护进程摘要用同一套组件与框线
- **事件日志与状态文件保持语言中立键**:告警判据、脚本与上报管道按事件名与字段取值,不读文案
- **文档暂时只做中文**:`README.md` 与 `docs/` 都是中文单语。英文文档等实现稳定后再补,现在不做——同时维护两份必然漂移(已经发生过:英文 README 的命令清单落后了整整一代)

## 依赖库的使用(严格遵守)

- **判断依赖库的能力、边界与错误行为,一律读它的源码**:模块依赖在 `.mooncakes/<组织>/<包>/src/`,随编译器发布的 core 在 WSL 的 `/root/.moon/lib/core/`。凡是要下「某个 API 会不会抛错、支不支持某语义」这类结论,先读实现,并在结论里给出源码位置
- **`.mbti` 只能当索引,或者干脆不读**:它不显示推断出来的错误类型——`@fs` 的 `.mbti` 里 `// Errors` 段是空的,而 `@fs.rename` 实际 `raise @os_error.OSError`。据此判断「失败即 abort」会得出完全相反的结论(已实证:轮转一度因此改用存在性探测,后全部回退为 try/catch)。拿不准时,读实现,或写一个临时探针用例跑一次
- **新增依赖前先确认它还在维护**,并优先用 core 自带的那份(core 随编译器发布,不必进 `moon.mod`)
- **测试专用依赖用 `import { ... } for "wbtest"` 声明**(`moon.pkg` 支持按目标声明依赖,可参考 `moonbitlang/core/json` 的写法):既避开 `unused_package` 告警,也不进发布产物

## 目录结构

- `docs/` — 手册(VitePress,中文单语;英文待实现稳定后再补)。依赖与构建在 Windows 侧跑,配置读 `moon.mod` 取版本与仓库地址,页面里不写版本号。部署在 `bm2.moonbitlang.dev`(子域名根路径,`base` 为 `/`),托管于 Cloudflare Pages 项目 `moonbit-bm2`,推送到 `main` 且 `docs/**` 或 `moon.mod` 有改动时自动重建;构建环境变量 `BUN_VERSION` 与 `SKIP_DEPENDENCY_INSTALL=1` 必设,值与原因见工作区规范 `NEW-PROJECT.md`。VitePress 精确锁在 `2.0.0-alpha.20`:依赖树从 126 个包降到 36 个,但 alpha 的破坏性变更**可能静默生效**(已遇到 `lastUpdatedText` 被移除且不报错),升级时逐个核对配置键;等 npm 的 `latest` 变成 2.x 再改成 `^2`
- `src/protocol` — CLI↔守护进程的线格式(Request / Response / 编解码 / 协议版本)
- `src/config` — bm2.toml 解析与校验(`[notify]` 订阅过滤也在此层)
- `src/core` — 进程监督领域:supervisor(主循环)/ command(控制面命令队列与应答)/ notify_runner(投递任务)/ rotate_runner(轮转任务)/ lifecycle(生命周期)/ exits(退出判定)/ limits(内存与端口)/ stats(统计),以及 alert(事件 → 多语言消息 → 报告)
- `src/fsx` — 文件读写、原子写、锁与有界读(含 C 桩)
- `src/ipc` — 长度前缀帧与子命令的收发(经 loopback TCP + 共享令牌)
- `src/log` — 事件日志与按大小轮转(大小与代数由 `[logs]` 配置,轮转走异步文件 API,不经过 `@fsx` 的 C 桩)
- `src/notify` — 通知投递包(模块内包,不是外部依赖:多平台 webhook 与 SMTP、去重与限流重试)
- `src/proc` — 进程与系统调用(spawn / pidfd / procfs / 信号,含 C 桩)
- `src/utils` — 纯函数工具(日期、文本与 JSON 辅助、版本比较)
- `src/cmd/bm2`、`src/cmd/bm2d` — 入口(main 分派 / daemon 连接 / render 输出 / update 升级);版本常量在 `src/cmd/bm2/version.mbt`

按能力分包、按功能分文件;`src/utils` 只放纯函数,有副作用的能力各自成包。命令 main 放 `src/cmd/<命令名>` 子包,二进制名与目录名一致。

- **构建产物路径随 moon 版本变动**(实测:`native/debug/build/<module>/<pkg>/x.exe` 变成 `native/debug/build/<pkg>/x.exe`):脚本一律按名字解析产物并校验它新于最新源文件,禁止硬编码产物路径——硬编码会在旧文件仍在原处时静默跑旧二进制,e2e 照样绿灯

## 文档写在哪里(严格遵守)

- **设计意图写在决策点的注释里**:为什么这样设计、为什么不能那样做,放在改这段代码时一定会看到的位置。`cmd_kill`、`Supervisor::tick`、`rotate.mbt` 顶部就是范本
- **整体视图写在模块顶部的块注释里**:任务模型、不变式、跨模块的时序与代价,一处写清,不拆到十个文件
- **不为同一件事建第二份文档**:本仓库没有 `specs/` 一类的契约目录。行为与取值只有一处真相(代码 + 测试名),需要提到别处时只放链接
- **改行为的提交必须同时动到注释或测试**:只改代码、任何一处说明都不动,视为漏做
- 用户面的事实(安装、升级、配置、命令、排障)在 `README.md` 与 `docs/`:代码注释不替代它们,用户不读源码
- **文档站只用纯 JavaScript**,不引入 TypeScript:配置文件是 `docs/.vitepress/config.js`(靠 `package.json` 的 `"type": "module"` 走 ESM)

## bm2d 监督循环(严格遵守)

- tick(50ms)内新增的周期性检查**必须自带时间闸**(参考 `check_notify` 的 `NOTIFY_CHECK_INTERVAL_MS` 模式):cron 分钟粒度检查用 60s 闸,重扫描用各自间隔闸;无闸的周期检查不予合入
- 到期/事件型检查(deadline/pending/removals 等)不加闸,但必须保证重复调用幂等
- **tick 内只发布,不做事**:通知投进 `Outbound` 队列、由 notify 任务投递与重试,日志轮转只发布一份待扫清单、由 rotate 任务用异步文件 API 执行(拷贝、改名、截断都不在 tick 里);`Supervisor::tick` 不含任何 await 点,网络与磁盘都不能拖慢监督心跳
- **控制面只经命令队列进入监督任务**:`bm2` 的请求变成 `Command` 投进 `Supervisor.commands`,由 tick 开头排空并就地应答;apps / instances / 重启预算只有监督任务一个写者(`bm2 notify` 例外:它只往通知队列投一条测试消息,不读被监督状态)

## 测试粒度

验证分三档,由内向外升级,**禁止拿全量当快检**(每改一步跑一次全量是错误用法):

1. **快检**(改完即跑,秒级):`moon check --deny-warn --warn-list +implicit_impl_as_method --target-dir _build-wsl`(单模块下无需指定包路径)
2. **模块测试**(功能完成时,十秒级):`moon test --target native`
3. **全量**(批次收尾一次):`bash scripts/devkit/verify.sh`(fmt / check / 单测 / 构建)。交付或发布前的端到端属于手动档,见下

e2e 不拆段不过滤(全部用例共享守护进程与状态,拆分省不了多少还添脆弱);测试内的 sleep 是真实时序语义,不为速度压缩。

**耗时的用例只手动跑(严格)**:e2e 与 soak 都是分钟级,任何无人值守的流程——pre-commit、pre-push(含打 tag 推送)、CI、发布——都**不执行**它们,只跑第 1、2、3 档。手动入口只有两个:`bash scripts/devkit/verify.sh --with-e2e`(仅 e2e)与 `--release`(e2e + soak)。**AI 助手同样不主动执行**:没有用户的明确指令,不得运行 e2e 与 soak,批次收尾的验证止于第 3 档。

**测前先换二进制(严格)**:任何命令测试与功能测试之前,先把最新源码构建到对应目录,并替换现有的 `bm2` 与 `bm2d`(安装位置 `/usr/local/bin`,先写临时名再 `mv`,避开 ETXTBSY)。守护进程必须一起换:配置由守护进程**重新读取并解析**,只换 CLI 会让新功能「在 CLI 通过、在守护进程报错」——错误不带 `bm2:` 前缀正是它来自守护进程的标志(已实证:数字占位符在 CLI 侧解析通过,旧守护进程用自己的旧解析器重读同一份配置后拒绝)。协议未变时 `bm2 reload` 即可换班,协议变了(如 v4→v5)只能 SIGTERM 后由新 CLI 自动拉起。

测试文件命名:`*_wbtest.mbt` 是白盒(测包内部实现,可直接调私有成员),`*_test.mbt` 是黑盒(测包的公开 API,用 `@包名.` 前缀调用);两者都放各包目录内,e2e 用例单独在 `scripts/e2e/`。

## 发布

本仓库的发布门禁是 `bash scripts/devkit/verify.sh`(fmt / check / 单测 / 构建);推 tag 时 `pre-push` 跑的也是这一档。e2e 与 soak 属于手动档,发布同样不自动执行它们——见上文「测试粒度」。

版本号在 `moon.mod` 与 CLI 的 `VERSION` 常量里必须一致(verify.sh 与 pre-commit 校验)。

## 提交格式(严格遵守)

```text
[项目名](类型) 提交内容
```

- **项目名**:一律 `bm2`。单仓库单项目,没有第二个项目名
- **类型**:`feat` / `fix` / `docs` / `refactor` / `test` / `chore`
- **提交内容**:一句话说明,中文,结尾不加句号

示例:

```text
[bm2](feat) 新增 reload 命令
[bm2](docs) 补充单模块结构说明
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
| `pre-push` | 推送时 | `bash scripts/devkit/verify.sh`(fmt / check / 单测 / 构建);e2e 由发布前手动跑 |

- 确需绕过:`git commit --no-verify`(例外应 rare)
- 钩子与验收门禁由工作区唯一源 `moonbit/scripts` 生成到 `scripts/devkit/`,**生成物禁改**(后果见该目录 README);项目只在 `scripts/devkit.conf` 里声明业务事实,慢测试挂在 `scripts/e2e/gate.sh` 与 `scripts/soak.sh` 两个插槽上

## 硬性约定

- **动词按层次分**:`kill` 只管守护进程;应用生命周期由 `stop`/`remove`/`clean` 表达。再出现「某个动词顺手管一下应用」的写法就是错的:同一个动词横跨两个层次,读的人得记两套语义,帮助文本自己也解释不清
- **项目是一个值**:项目级状态一律进 `Project` 的字段,不在 `Supervisor` 上按项目名新开一张表。加字段是加字段;新开表则是给「注销」再加一处必须记得清的义务,而人一定会忘(已经漏过一次:旧版的 `config_paths` 从未被清除,重名再注册时拿旧路径去比对)
- 仅 Linux(内核 >= 5.3,pidfd),不引入跨平台抽象层
- 配置不执行 shell 字符串;启动命令固定为参数数组
- 环境变量值不得写入状态文件、事件、crash 日志或 CLI 输出
- 状态文件一律原子写(经 `@fsx.write_atomic`)
- 子进程只带自己的 stdio 启动:daemon 持有的任何 fd(pidfd / socket / tty)要么 CLOEXEC,要么由 spawn 在 execve 前统一关闭——应用不得继承守护进程的 fd
- 注销项目必须清干净按项目状态:内存 map、通知队列与限流/去重状态一并回收,同名项目重新注册不得继承上一代的数字
- 通知的端点与凭据(`url`/`secret`/`username`/`password`)不得进入事件、状态、日志与 CLI 输出;校验错误只报字段名与 `target[i]` 下标
- 通知投递失败只记事件,绝不改变监督行为
- 网络能力(HTTP/SMTP)由内联的 notify 库提供,bm2 内不自实现、不引入 curl
