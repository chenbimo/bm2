# 06 · 日志与轮转

- 状态: active
- 覆盖测试: `src/core/rotate_runner_wbtest.mbt`、`src/log/log_wbtest.mbt`、e2e 段 U / AK
- 与代码对账: 2026-10-13

## 布局与归属

```
<state_dir>/<name>/logs/<name>-<id>.out.log     应用 stdout,进程持有 fd
<state_dir>/<name>/logs/<name>-<id>.error.log   应用 stderr,进程持有 fd
<state_dir>/<name>/logs/<name>-<id>.crash.log   我们写的异常退出诊断
<state_dir>/bm2d.events.jsonl                   守护进程事件
<state_dir>/bm2.events.jsonl                    CLI 事件(一次调用一行)
<state_dir>/bm2d.log                            守护进程 stderr
```

前三份属于项目,轮转策略随项目的 `[logs]` 走。后三份**不属于任何项目**,统一用内置策略(默认 10 MB / 代数不限)。

## 轮转语义

- 单个文件超过 `[logs] max_size_mb` 时轮转一次
- `[logs] keep` 决定保留几代归档;`keep = 0`(默认)**不限制代数**,磁盘占用由使用者自己决定何时收手
- 应用 stdout/stderr 用 **copytruncate**:进程持有 fd,不能 rename,只能拷出去再原地清空。拷贝期间写入的少量字节会丢,这是 fd 被持有的代价
- crash 日志与事件日志用 **rename**:没有别的写者持有 fd
- 代数上限不是固定值:有 `keep` 时从 `keep-1` 往下走,不限时先读目录里的最高代号。重启后没有内存计数可依赖,只能看盘

## 在独立任务上执行

尺寸检查与轮转都搬出了监督 tick(见 `01`):tick 只发布一份待扫清单,rotate 任务用异步文件 API 执行。单条日志最多 10 MB,慢盘上一次拷贝足以同时拖住 deadline、投递与 accept。

轮转失败只记事件(`log_rotate_failed`),绝不改变监督行为。

## 事件日志

JSONL,每行一个对象,键保持语言中立(面向人读的文案另有 `lang` 决定)。不得包含环境变量值、端点凭据或协议负载。
