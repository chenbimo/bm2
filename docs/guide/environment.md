# 环境变量

## 一个来源：`.env` 文件

项目的环境变量只有一个来源：与 `bm2.toml` 并排的 `.env` 文件。`bm2.toml` 只消费它们，不定义变量。

启动时扫描四个文件，从低到高，后者覆盖前者：

1. `.env`
2. `.env.<模式>`
3. `.env.local`
4. `.env.<模式>.local`

`<模式>` 由命令决定，只有两种取值：`bm2 serve` 是 `production`，`bm2 dev` 是 `development`。

文件不存在是正常的，四个里通常只有一两个。存在却读不了、或者写错了则是硬错误，报错会点名文件和行号。

解析规则跟随 Node 生态的事实标准 `dotenv`：支持 `export` 前缀、单双引号、双引号内的 `\n` 转义、`#` 注释（`#` 前有空白才算行尾注释，所以 `a#b` 是值）。

`.env` 文件里**不做** `${VAR}` 展开，展开是 `bm2.toml` 的能力，不是 `.env` 的。

```bash
# .env
MYSQL_HOST=127.0.0.1

# .env.production
MYSQL_HOST=db.internal
LOG_LEVEL=warn
```

bun 自己也会自动加载这些文件。bm2 先读一遍再注入，是为了让 bun 与 node 两种运行时行为一致，而不是各自依赖运行时的实现——node 默认并不加载它们。

## 注入顺序

从低到高，后者覆盖前者：

1. 白名单变量的当前值（`PATH`、`HOME`、`TMPDIR`）
2. 扫描出来的项目环境
3. 保留变量（`BM2_*`、`NODE_ENV`）——**永远覆盖不了**

顺序不随文件书写顺序变化。保留变量排最后，因为实例的自我描述不应该由一个应用的配置文件改写。

## 只传三个白名单变量

除了保留变量和扫描出来的项目环境，bm2 只把自己环境里的 `PATH`、`HOME`、`TMPDIR` 传给被托管的进程。你 shell 里的其它变量不会跟着进去——应用拿到的是最小环境，而不是你终端里的一整套。

## 保留变量

| 变量 | 值 |
| --- | --- |
| `BM2_APP_NAME` | 项目名 |
| `BM2_INSTANCE_ID` | 实例编号，第一个实例为 `"0"` |
| `BM2_APP_INSTANCE` | 同实例编号，命名对齐 PM2 的 `NODE_APP_INSTANCE` 习惯 |
| `BM2_APP_PORT` | 分配给该实例的端口 |
| `NODE_ENV` | 由命令决定：`bm2 serve` 是 `production`，`bm2 dev` 是 `development` |

`BM2_APP_PORT` 的取值取决于执行模式：cluster（默认）下恒为配置里的 `port`；fork 模式下等于 `port` 加实例编号，所以 `port = 3000`、`instances = 3` 时三个实例分别拿到 `3000`、`3001`、`3002`。

`NODE_ENV` 归在保留变量里，因为模式是人的输入，不是应用的产出。`.env` 文件里可以把它写成同一个值（很多 `.env.production` 里就有那一行），写成别的值会被当场拒绝——否则"我在哪个环境"就取决于哪份文件最后被读到。

## `${VAR}` 也读同一份项目环境

`bm2.toml` 里的 `${VAR}` 先查扫描出来的项目环境，再查 bm2 进程自己的环境。端点、密钥这些就不必写进 `bm2.toml`，也不会跟着仓库走。

```toml
name = "api"
script = "src/index.ts"
instances = 2
port = ${APP_PORT}

[notify]
mail_url = "smtp://${MYSQL_HOST}:25"
```

同一个值既解析进配置，也注入给应用，所以应用和管理者不可能对同一个名字读出不同的值。两边都找不到该变量时报错并点名它，绝不静默变成空值——空 URL 不该变成一次投递尝试。

## 两套模式，同一套监督

`bm2 serve` 与 `bm2 dev` 只决定读哪些 `.env` 文件，监督行为完全相同：崩溃重启、内存上限、重启风暴预算、通知上报一视同仁。调试时的行为必须和线上一致，否则调试本身就没有意义。

模式记在项目的注册记录里，所以 `bm2 list` 看得到，`bm2 reload` 也不会把一个 dev 项目悄悄变回 production。

## 应用里的典型用法

- 用 `BM2_APP_PORT` 绑定监听端口。
- 用 `BM2_APP_INSTANCE === "0"` 判断主实例，只在主实例跑数据库迁移、定时任务这类一次性逻辑。
- 用 `NODE_ENV` 区分构建产物与调试开关。

```js
const PORT = Number(process.env.BM2_APP_PORT ?? 3000);
const isPrimary = process.env.BM2_APP_INSTANCE === "0";

Bun.serve({ port: PORT, fetch: () => new Response("ok") });

if (isPrimary) {
  // 只在主实例执行：数据库迁移、定时任务等
}
```
