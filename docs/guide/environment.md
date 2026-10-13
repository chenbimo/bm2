# 环境变量

## `[env]` 注入

`bm2.toml` 的 `[env]` 表为应用注入自定义环境变量，值必须是字符串。它写在项目根表之后：

```toml
[env]
MYSQL_HOST = "127.0.0.1"
MYSQL_PORT = "3306"
```

注入顺序固定，从低到高，后者覆盖前者：

1. 白名单变量的当前值
2. `[env]` 表
3. 保留变量（`BM2_*`、`NODE_ENV`、`PATH`）——**永远覆盖不了**

顺序不随配置书写顺序变化。保留变量排最后，因为实例的自我描述不应该由一个配置文件改写。

## 只传三个白名单变量

除了保留变量，bm2 只把自己环境里的 `PATH`、`HOME`、`TMPDIR` 传给被托管的进程。调用 bm2 的那个 shell 里的其它变量不会跟着进去——应用拿到的是一个最小环境，而不是你终端里的一整套。

## 保留变量

| 变量 | 值 |
| --- | --- |
| `BM2_APP_NAME` | 项目名 |
| `BM2_INSTANCE_ID` | 实例编号，第一个实例为 `"0"` |
| `BM2_APP_INSTANCE` | 同实例编号，命名对齐 PM2 的 `NODE_APP_INSTANCE` 习惯 |
| `BM2_APP_PORT` | 分配给该实例的端口 |
| `NODE_ENV` | 恒为 `"production"` |

`BM2_APP_PORT` 的取值取决于执行模式：cluster（默认）下恒为配置里的 `port`；fork 模式下等于 `port` 加实例编号，所以 `port = 3000`、`instances = 3` 时三个实例分别拿到 `3000`、`3001`、`3002`。

## 应用里的典型用法

- 用 `BM2_APP_PORT` 绑定监听端口。
- 用 `BM2_APP_INSTANCE === "0"` 判断主实例，只在主实例跑数据库迁移、定时任务这类一次性逻辑。
- 用 `NODE_ENV === "production"` 走生产分支。

```js
const PORT = Number(process.env.BM2_APP_PORT ?? 3000);
const isPrimary = process.env.BM2_APP_INSTANCE === "0";

Bun.serve({ port: PORT, fetch: () => new Response("ok") });

if (isPrimary) {
  // 只在主实例执行：数据库迁移、定时任务等
}
```

## bm2 不碰应用自己的环境

应用自身的环境变量由应用与运行时自行加载。bm2 不解析 `.env`，也不参与加载它。

bun 与 node 都不会用 `.env` 文件覆盖已存在的变量，所以 `[env]` 的值优先于项目自带的 env 文件——bm2 注入的变量同样不会被 `.env` 覆盖。
