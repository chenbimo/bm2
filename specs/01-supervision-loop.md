# 01 · 监督循环

- 状态: active
- 覆盖测试: `src/core/supervisor_wbtest.mbt`、`src/core/core_test.mbt`、e2e 段 T
- 与代码对账: 2026-10-13

## 任务模型

守护进程只有四个长期任务,各自持有自己的状态,谁都拖不动别人:

| 任务 | 职责 | 节奏 |
| --- | --- | --- |
| supervise | 唯一的监督状态写者;跑 `tick` | 50 ms |
| notify | 唯一的网络出口:去重、限流、重试、投递 | 50 ms |
| rotate | 唯一的日志拷贝者 | 阻塞等队列 |
| control | 每连接一个子任务,上限 64(`Semaphore`) | 按请求 |

测试之外的意图是:任何一个任务卡住,其余三个照常。

## tick 的契约

`Supervisor::tick` 是**同步函数,不含任何 await 点**。这是本项目最重要的一条工程约束:网络与磁盘都不允许拖慢监督心跳。

顺序固定,不得随意调整:

1. `drain_commands` — 控制面请求在此就地应用
2. `reap` / `check_reaps` — 回收退出与失败 spawn 的孤儿
3. 时间闸扫描:`check_memory`(5 s)、`publish_rotation`(10 s)
4. 到期与事件型检查:`check_reuseport`、`check_deadlines`、`check_restarts`、`check_pending`、`check_removals`
5. `check_notify` / `check_schedules` — 只发布,不投递

**新增周期性检查必须自带时间闸**(参考 `NOTIFY_CHECK_INTERVAL_MS`)。到期/事件型检查不加闸,但必须幂等——重复调用不得产生第二次副作用。

## 时钟

所有闸门、退避与期限一律用单调时钟(`@proc.monotonic_ms`),系统时间跳变既不能卡死扫描也不能让它每 tick 都跑。墙钟只用在人要读绝对时间的地方(cron 字段、消息时间戳、状态文件里的 ISO 时间)。

## 单写者

`projects`(含实例、标记、统计)、重启预算、风暴历史只有 supervise 任务写得动。控制面不是第二个写者:它把请求变成 `Command` 投进队列,由 tick 开头排空并就地应答。

## tick 内只发布,不做事

昂贵的、会阻塞的活动一律搬出 tick:

- 通知投递 → notify 任务
- 日志尺寸检查与轮转 → rotate 任务
- 运行时版本探测 → 控制侧(启动请求的预检)
- 孤儿进程回收 → tick 内只做非阻塞尝试,窗口摊到多轮

违反这条的最典型后果不是慢,是**连带延迟**:一次 tick 里等半秒,deadline、投递与 accept 全部延后。
