# 06 · 日志与轮转

- 状态: active
- 覆盖测试: 见文末「条目 → 测试」表
- 与代码对账: 2026-10-13

## 布局与归属

| 路径 | 内容 | 写者 |
| --- | --- | --- |
| `<name>/logs/<name>-<id>.out.log` | 应用 stdout | 应用自己(持有 fd) |
| `<name>/logs/<name>-<id>.error.log` | 应用 stderr | 应用自己(持有 fd) |
| `<name>/logs/<name>-<id>.crash.log` | 异常退出诊断 | 守护进程 |
| `<state_dir>/bm2d.events.jsonl` | 守护进程事件 | 守护进程 |
| `<state_dir>/bm2.events.jsonl` | CLI 事件(一次调用一行) | CLI |
| `<state_dir>/bm2d.log` | 守护进程 stderr | 守护进程 |

前三份属于项目,轮转策略随项目的 `[logs]` 走。后三份**不属于任何项目**,统一用内置策略(`LogsConfig::builtin()`,默认 10 MB / 代数不限)。

## 轮转语义

- 单个文件超过 `[logs] max_size_mb` 时轮转一次
- `[logs] keep` 决定保留几代归档;**`keep = 0`(默认)不限制代数**
- 代数上限不是固定值:有 `keep` 时从 `keep-1` 往下走;不限时先读目录里的最高代号再往后排。重启后没有内存计数可依赖,只能看盘

## 两种轮转方式,不能混用

| 对象 | 方式 | 原因 |
| --- | --- | --- |
| 应用 stdout / stderr | **copytruncate**:先拷出去再原地清空 | 应用持有 fd,rename 之后它继续写旧 inode,新文件永远是空的 |
| crash 日志、事件日志 | **rename**:先改名再新建 | 没有别的写者持有 fd |

copytruncate 会丢掉拷贝期间写入的少量字节。这是 fd 被持有的代价,不是实现缺陷。

代数链的迁移:`<name>.log` → `<name>.log.1` → `.2` …,每轮从高到低平移,最高代超上限时删除。

## 在独立任务上执行

尺寸检查与轮转都在 rotate 任务上(见 `01`):tick 只发布一份待扫清单,rotate 用异步文件 API 执行。单条日志上限 10 MB,慢盘上一次拷贝足以同时拖住 deadline、投递与 accept。

**轮转失败只记事件(`log_rotate_failed`),绝不改变监督行为。**

## 事件日志

JSONL,每行一个对象,键保持语言中立(面向人读的文案另有 `lang` 决定)。不得包含环境变量值、端点凭据或协议负载。

## 边界情形

| 情形 | 表现 |
| --- | --- |
| 应用正在写时轮转 | copytruncate,可能丢拷贝期间写入的少量字节 |
| `keep = 0` 且目录里已有旧代数 | 从盘上读到的最高代号继续,不从头开始 |
| 日志文件不存在 | 跳过,不报错 |
| 轮转出错(权限、磁盘满) | 记事件,下次扫描继续尝试 |
| 应用被退役 | 日志默认保留,`remove -f` 才连目录一起删 |

## 条目 → 测试

| 条目 | 覆盖它的测试 |
| --- | --- |
| 按大小触发轮转 | e2e 段 U |
| 跨项目轮转互不干扰 | e2e 段 AK |
| 代数链迁移与上限 | `src/core/rotate_runner_wbtest.mbt` |
| 最高代数从盘上读(`keep = 0`) | `src/log/log_wbtest.mbt` |
| 轮转失败不致命 | `src/core/rotate_runner_wbtest.mbt` |
