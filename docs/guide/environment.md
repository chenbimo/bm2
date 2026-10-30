# 环境变量

应用拿到的环境是**最小集合**，不是启动 `bm2` 的那个 shell 的全部。

这是一种取舍：代价是 `export FOO=1` 不会跟着进应用，收益是同一份配置在任何机器上都跑出同一个环境。

## 一个来源：`.env` 文件

项目的环境变量只有一个来源：与 `bm2.toml` 并排的 `.env` 文件。`bm2.toml` 只消费它们，不定义变量，也没有 `[env]` 这样的表（写了会被当成未知字段拒绝）。

启动时按固定顺序扫描四个文件，后者覆盖前者：

| 顺序 | 文件 | 说明 |
| --- | --- | --- |
| 1 | `.env` | 通用 |
| 2 | `.env.<模式>` | `production` 或 `development` |
| 3 | `.env.local` | 本机覆盖，通用 |
| 4 | `.env.<模式>.local` | 本机覆盖，按模式 |

`<模式>` 由命令决定，只有两种取值：`bm2 serve` 是 `production`，`bm2 dev` 是 `development`。

文件不存在是正常的，四个里通常只有一两个。存在却读不了、或者写错了是硬错误，报错点名文件与行号。

```bash
# .env
MYSQL_HOST=127.0.0.1

# .env.production
MYSQL_HOST=db.internal
LOG_LEVEL=warn
```

## 解析规则

跟随 Node 生态的事实标准 `dotenv`，不发明自己的方言。

- `KEY=VALUE`，值两侧空白会去掉。
- `export KEY=VALUE` 允许，`export` 后面必须是空白，`exportFOO=1` 的键是 `exportFOO`。
- 单引号与双引号包裹的值。引号内可以跨行。
- 双引号内支持 `\n` `\t` `\r` `\\` `\"` 转义，单引号内一律字面。
- `#` 起注释：整行注释，或未加引号的值后面以空白开头的行尾注释。所以 `a#b` 是值，`a #b` 是值 `a`。
- 空值 `KEY=` 合法。
- 重复键后者覆盖前者。

**`.env` 里不做变量展开。** `FOO=${BAR}` 的字面值就是 `${BAR}`，展开是 `bm2.toml` 占位符的能力，不是 `.env` 的。应用自己会展开它读到的值。

解析失败即拒绝，并指出文件与行号。

```text
InvalidDocument: /srv/api/.env line 4: expected '=' after DATABASE_URL
```

## `NODE_ENV` 由模式决定

`NODE_ENV` 是保留变量，值就是模式：`bm2 serve` 是 `production`，`bm2 dev` 是 `development`。

`.env` 文件里可以写同一个值（很多 `.env.production` 里就有那一行），但写成**别的**值会被当场拒绝。

```text
InvalidField: NODE_ENV is production in this mode, but a .env file sets development
```

理由：否则「我在哪个环境」就取决于哪份文件最后被读到，而这件事不能由应用的配置文件决定。

## 注入顺序

从低到高，后者覆盖前者：

| 顺序 | 来源 | 例子 |
| --- | --- | --- |
| 1 | 守护进程环境里的白名单变量 | `PATH`、`HOME`、`TMPDIR` |
| 2 | 守护进程环境里所有 `BM2_` 开头的变量 | `BM2_FEISHU_WEBHOOK` |
| 3 | 项目扫出来的 `.env` 变量 | `DATABASE_URL` |
| 4 | 保留变量 | `BM2_APP_*`、`NODE_ENV` |

顺序与文件的书写顺序无关，只由这张表决定。

第 2 条是一个容易被忽略的通道：以 `BM2_` 开头的变量会从守护进程的环境透传到应用，同时也能被 `bm2.toml` 的占位符读到。这也是为什么通知凭据可以只在 shell 里 `export` 一次。

第 4 条排最后，因为实例的自我描述不应该由应用的配置文件改写。

## 白名单只有三个

除了保留变量、项目环境和 `BM2_*` 透传，bm2 只把自己环境里的 `PATH`、`HOME`、`TMPDIR` 传下去。你 shell 里的其它变量不会跟着进去。

`PATH` 尤其重要：运行时是按名字经 `PATH` 解析的（`execvpe`），所以守护进程的 `PATH` 决定了应用用哪个 `bun` / `node`。

守护进程的 `PATH` 在它启动那一刻定格。装了新版 Bun 或 Node.js 之后，先 `bm2 reload` 换入新守护进程，再用到它的项目才能看到新版本。

## 保留变量

| 变量 | 值 |
| --- | --- |
| `BM2_APP_NAME` | 项目名 |
| `BM2_INSTANCE_ID` | 实例编号，第一个实例为 `"0"` |
| `BM2_APP_INSTANCE` | 同实例编号，命名对齐 PM2 的 `NODE_APP_INSTANCE` 习惯 |
| `BM2_APP_PORT` | 分配给该实例的端口 |
| `NODE_ENV` | `bm2 serve` 是 `production`，`bm2 dev` 是 `development` |

`BM2_APP_PORT` 的取值取决于执行模式：

| 模式 | `port = 3000`、`instances = 3` 时的取值 |
| --- | --- |
| `cluster` | 三个实例都是 `3000` |
| `fork` | `3000`、`3001`、`3002` |
| `bm2 dev` | 只有一个实例，恒为 `3000` |

保留变量同时也是守护进程重启后「认领」实例的依据：一个进程的 `/proc/<pid>/environ` 里带着这三个值，才能证明它是 bm2 拉起的。缺失或不匹配的进程永远不会被接管。

## `__NAME__` 占位符读同一份项目环境

`bm2.toml` 里的字符串可以引用环境变量，标记写在引号里。

```toml
name = "api"
script = "__APP_ENTRY__"
instances = 2
port = "__APP_PORT__"

[notify]
mail_url = "smtp://__MYSQL_HOST__:25"
```

查找顺序：先查扫出来的项目环境（`.env` 系列），再查 bm2 进程自己的环境。

这里的「bm2 进程」实际是**守护进程**：它才是真正读配置、注入环境的那一个。所以能在占位符里用的 shell 变量，只有 `.env` 里的、以及启动时已存在于守护进程环境里的 `BM2_*` 变量。想用别的前缀，写进 `.env`。

```bash
# .env.production
APP_ENTRY=dist/server.js
APP_PORT=3000
```

四条规则：

- 标记必须待在引号里。不带引号的 `__APP_PORT__` 不是 TOML 的值，文件当场就不合法了。
- 数字与布尔字段也写引号里的标记，展开后按字段类型解析。`port = "__APP_PORT__"` 遇到 `APP_PORT=abc` 会报错并点名字段，而不是带着坏端口进入托管。
- 展开发生在**解析之后**，只作用于解析出的字符串值。所以注释里的 `__NAME__` 只是散文，不会因为变量没设而报错。
- 没有配对下划线的 `a__b` 是普通文本。变量没设置是硬错误，绝不静默变成空值。

```text
InvalidField: notify.mail_password references environment variable BM2_MAIL_PASSWORD which is not set
```

变量名只允许字母、数字、下划线，且不能以数字开头。

为什么用两个下划线而不是 `$`：`$` 在 URL 与密码里太常见，凭据里一个大括号手滑就可能被当成占位符。`__NAME__` 这个形状几乎不会碰巧出现在普通文本里。

## 两套模式，同一套监督

`bm2 serve` 与 `bm2 dev` 只决定读哪些 `.env` 文件，以及 `NODE_ENV` 的值。监督行为完全相同：崩溃重启、内存上限、重启预算、日志轮转、通知上报一视同仁。

实例数不一样：开发模式只跑一个实例，配置里的 `instances` 不生效。

`bm2 check` 会把两份配置各读一遍，所以「生产能跑、开发读不到变量」这种问题在校验阶段就会暴露。

## 应用里的典型用法

```js
const port = Number(process.env.BM2_APP_PORT ?? 3000)
const isPrimary = process.env.BM2_APP_INSTANCE === "0"

Bun.serve({
  port,
  // cluster 模式必须开，fork 模式无所谓
  reusePort: true,
  fetch: () => new Response(process.env.NODE_ENV ?? "-"),
})

if (isPrimary) {
  // 只在主实例执行：数据库迁移、定时任务等一次性逻辑
}
```

- 端口一定读 `BM2_APP_PORT`，不要写死。
- 一次性逻辑放 `BM2_APP_INSTANCE === "0"`，bm2 只负责注入编号。
- `NODE_ENV` 用来区分构建产物与调试开关。

## 变量没生效时的排查顺序

1. 模式对不对：`serve` 读 `.env.production`，`dev` 读 `.env.development`。
2. 变量名是不是白名单之外、又不带 `BM2_` 前缀：这种变量不会从 shell 进应用。
3. 有没有被更高优先级的文件覆盖：`.env.<模式>.local` 覆盖一切。
4. 装了新运行时没换班：`bm2 reload` 之后再 `bm2 serve`。

```bash
cat /proc/$(pgrep -f 'dist/server.js' | head -1)/environ | tr '\0' '\n' | sort
```

上一行可以看到某个实例真实拿到的环境。它同时也是守护进程重启后判断「这个进程是不是我的」的依据。
