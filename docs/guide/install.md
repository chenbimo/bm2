# 安装与升级

bm2 由两个二进制组成：命令行 `bm2` 与守护进程 `bm2d`。两者一起安装，并且都必须留在 `PATH` 中，因为 `bm2` 通过名字启动 `bm2d`。

## 环境要求

- **仅支持 Linux。** 非 Linux 构建会拒绝运行并说明原因。
- **Linux 内核 >= 5.3**，pidfd 进程跟踪需要。
- **[MoonBit](https://www.moonbitlang.com/)**：安装与升级 bm2 时需要，运行不需要。
- **[Bun](https://bun.sh/) >= 1.4.0**：`runtime = "bun"` 的项目需要。
- **[Node.js](https://nodejs.org/) >= 24.0.0**：仅 `runtime = "node"` 的项目需要。

`bm2 serve` 会实测运行时版本，低于下限时拒绝启动并给出具体提示。检查发生在你敲下 `start` 的那一刻，而不是实例反复崩溃之后。

## 安装

先安装 MoonBit 工具链：

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
```

再安装 bm2：

```bash
moon install chensuiyi/bm2/...
```

bm2 默认安装到 moon 工具链所在的 `~/.moon/bin`，无需配置 `PATH`。

## 升级

```bash
bm2 upgrade
```

`upgrade` 会比对发布站上的版本与当前版本、下载本平台的这两个二进制、逐一校验 SHA256、在保留回滚备份的前提下换入，最后把守护进程交给新二进制。整个换班过程中应用继续运行。

任何一步失败，二进制要么保持原样，要么从备份恢复。

## 装了新运行时之后

守护进程的 `PATH` 在它启动的那一刻定格。安装了更新的 Bun 或 Node.js 之后，先执行 `bm2 reload` 换入新守护进程，再启动用到它的项目。
