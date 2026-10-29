# 安装与升级

bm2 由两个二进制组成：命令行 `bm2` 与守护进程 `bm2d`。

两者一起安装，也必须留在同一目录并在 `PATH` 里，因为 `bm2` 是按名字启动 `bm2d` 的。

## 环境要求

- **仅支持 Linux。** 非 Linux 构建会拒绝运行并说明原因。
- **内核 >= 5.3**，pidfd 进程跟踪需要。
- **[MoonBit](https://www.moonbitlang.com/)** 工具链：安装与升级 bm2 时需要，运行 bm2 不需要。
- **[Bun](https://bun.sh/)** `1.4.0` 及以上：`runtime = "bun"` 的项目需要。
- **[Node.js](https://nodejs.org/)** `24.0.0` 及以上：只有 `runtime = "node"` 的项目需要。

运行时版本在启动那一刻实测，低于下限直接拒绝启动并说清缺什么。

这条检查比「先起再崩」有用得多：它把问题定位在启动之前，而不是让你从一堆崩溃日志里猜。

## 安装

先装 MoonBit 工具链。

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
```

再装 bm2。

```bash
moon install chensuiyi/bm2/...
```

两个二进制落到 `~/.moon/bin`，这个目录通常已经在 `PATH` 里，不需要额外配置。

确认装好。

```bash
bm2 --version
which bm2 bm2d
```

两条命令都指向同一个目录才算正确。

`bm2d` 找不到时的表现很明确：任何需要守护进程的命令都会报 `bm2: bm2d did not start`，并告诉你去看 `~/.bm2/bm2d.log`。

### 从 GitHub Releases 下载安装

不想装 MoonBit 工具链时，从 [Releases](https://github.com/chenbimo/bm2/releases) 下载对应架构的 `bm2` 与 `bm2d`，**放进 `~/.moon/bin`**。

```bash
mkdir -p ~/.moon/bin
mv bm2 bm2d ~/.moon/bin/
chmod +x ~/.moon/bin/bm2 ~/.moon/bin/bm2d
```

`~/.moon/bin` 通常已经在 `PATH` 里，装完直接可用；如果不在，把 `export PATH="$HOME/.moon/bin:$PATH"` 写进 `~/.profile`。

**为什么一定要放这个目录**：`moon install` 也装这里，`bm2 upgrade` 替换的正是这一份。放到别处，升级装的是 `~/.moon/bin` 里那份，跑起来的还是你放的那份。

这条装法没有自升级：`bm2 upgrade` 依赖 `moon` 命令，机器上没有它会直接说明，不会假装成功。要升级就重新下载，覆盖同一个目录。

## 升级

```bash
bm2 upgrade
```

它做的事按顺序是：查 mooncakes 上的最新版本、用 `moon install` 换入两个二进制、把守护进程交给新二进制。

应用全程继续运行。

升级需要本机有 `moon` 命令。如果你是直接下载 GitHub Release 的产物手工放的，机器上通常没有 moon，这条命令会告诉你改用哪种方式，而不是自己去下载一套。

`moon install` 失败时旧版本原样保留，不会留下半套新版本。

已经是最新版本时它直接告诉你，不做无谓的安装。

## 只换二进制

手工替换过二进制，或者只想让新版本立刻生效时。

```bash
bm2 reload
```

旧守护进程退场，新守护进程接管仍在运行的实例，PID 不变。

`bm2` 与 `bm2d` 会互相校验协议版本。版本不一致时，提示会直接指向这一条命令，而不是给一个查不到原因的错误。

## 装了新运行时之后

守护进程的 `PATH` 在它启动那一刻定格。

装了新版 Bun 或 Node.js 之后，先用 `bm2 reload` 换入新守护进程，用到它的项目才能看到新版本。

跳过这一步的典型症状是：`which bun` 已经是新版，`bm2 list` 里的项目却还在报版本过低。

## 多用户与权限

一个用户一个守护进程，状态目录是 `~/.bm2`，权限 `0700`。

被托管的应用以守护进程的用户身份运行，文件权限、环境变量与日志归属都跟着走。

不要把 bm2 装在 root 下管理属于其它用户的应用，也不要让两个用户共享同一个状态目录。

## 在 WSL 里

可以跑，前提是 WSL2：它提供完整内核，pidfd 可用。WSL1 不支持。

两点差异要知道：WSL 与 Windows 共享端口空间，端口冲突要在两边一起看。WSL 实例关闭后里面的进程会停止，长期服务不要放在本机的 WSL 里。

## 卸载

先停掉全部项目与守护进程。

```bash
bm2 kill -y
```

再删二进制与状态目录。

```bash
rm -f ~/.moon/bin/bm2 ~/.moon/bin/bm2d
rm -rf ~/.bm2
```

`~/.bm2` 里有日志与事件记录，需要留档就先备份再删。

## 常见安装问题

`bm2: bm2d did not start`：两个二进制不在同一目录，或 `bm2d` 没有执行权限。

`Permission denied`：`~/.bm2` 属于别的用户，或者当前用户没有写权限。

`bm2: refusing to stop bm2d and all apps`：`kill` 需要 `-y` 确认，这是防止误杀的拦截。

更细的排障见[排障与常见问题](/guide/troubleshooting)。
