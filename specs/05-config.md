# 05 · 配置

- 状态: active
- 覆盖测试: `src/config/config_test.mbt`、`src/config/notify_test.mbt`、`src/cmd/bm2/check_wbtest.mbt`、e2e 段 S
- 与代码对账: 2026-10-13

## 文件

`bm2.toml` 在项目目录里,一个文件配置一个项目。`bm2 check` 单独校验它;`bm2 start` 也会先校验,不合法就不启动。

## 字段

| 字段 | 默认 | 约束 |
| --- | --- | --- |
| `name` | 必填 | `[A-Za-z][A-Za-z0-9_]*`,全局唯一 |
| `cwd` | 配置文件所在目录 | 必须绝对路径 |
| `script` | 必填 | 相对 `cwd`,禁 `..` 段 |
| `runtime` | `bun` | `bun` 或 `node` |
| `exec_mode` | `cluster` | `cluster`(共享端口,靠 SO_REUSEPORT)或 `fork`(端口从 `port` 起连续分配) |
| `instances` | 必填 | 1..1024 |
| `port` | 必填 | 1..65535;与**所有已注册项目**的范围不得重叠 |
| `max_memory_mb` | 512 | 1..1048576 |
| `max_restarts` | 10 | ≥ 0;0 表示首次异常即 errored |
| `restart_delay_ms` | 1000 | ≥ 0 |
| `min_uptime_ms` | 10000 | ≥ 0 |
| `stop_timeout_ms` | 10000 | 1..60000 |
| `[logs] max_size_mb` | 10 | 1..102400 |
| `[logs] keep` | 0 | 0..1000,0 表示代数不限 |
| `[notify]` | 关闭 | 见 `07` |
| `[env]` | 空 | 键须为合法变量名,值须为字符串 |

未知字段一律拒绝——拼错一个字段名而静默生效,比启动失败更难查。

## 校验在解析期,不做兜底

越界的值直接拒绝,不夹取、不取默认:

- `logs.max_size_mb = 0` 会让日志**静默地永不轮转**,所以它不是一个合法值
- `logs.keep` 为负无意义
- 端口范围重叠会让两个项目抢同一个端口

拒绝的理由要具体到字段名与冲突对象(例如端口冲突要点名另一个项目)。

## 不做的事

配置不执行 shell 字符串;启动命令固定为参数数组,这是不可回退的设计。环境变量值不得写入状态文件、事件、crash 日志或 CLI 输出。
