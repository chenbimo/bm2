# bm2 设计规范

这里是 bm2 的行为契约。**约束外部可见行为的东西写在这里**,约束我们怎么干活的写在根目录 `AGENTS.md`——那个文件只做索引,正文指向这里。

## 清单

| 编号 | 主题 | 状态 |
| --- | --- | --- |
| [01](01-supervision-loop.md) | 监督循环:任务模型、tick 契约、时钟、单写者 | active |
| [02](02-project-identity.md) | 项目身份与状态目录:名字 + 配置路径、`Project` 这个值、注销出口 | active |
| [03](03-command-surface.md) | 命令面:词汇表、层次原则、退出码 | active |
| [04](04-wire-protocol.md) | CLI↔守护进程线协议:帧、字段、升版规则 | active |
| [05](05-config.md) | 配置:字段表与校验规则 | active |
| [06](06-logs-and-rotation.md) | 日志与轮转:布局、copytruncate 与 rename、`keep = 0` | active |
| [07](07-notify.md) | 通知:分工、线上契约、限流重试 | active |
| [08](08-state-and-recovery.md) | 状态文件与恢复:原子写、收养、无主目录的判据 | active |
| [09](09-runtime-and-spawn.md) | 运行时与 spawn:会话、fd 卫生、环境、崩溃预算、善后 | active |
| [10](10-self-upgrade.md) | 自升级:清单、事务回滚、换班顺序、签名不做的理由 | active |

## 三条使用规矩

**契约变更顺序有硬约束:先改 specs → 再改实现 → 跑对应测试。** 反过来的话,规范就成了对既成事实的追认,而不是设计。

**每篇头部三行不许省**:状态、覆盖它的测试、与代码对账的日期。没有对账日期的契约,半年后没人敢信。

**spec 不得比它描述的代码更长。** 一份读起来比代码还费劲的规范,结果是没人读。

## 能力边界

规范写「现状 + 为什么」。历史沿革、待办、过程记录一律不在这里——那些是提交信息和 `AGENTS.md` 的事。`specs/` 里只留仍然生效的约定。
