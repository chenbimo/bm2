# 网络与国内镜像

moon 默认从 `mooncakes.io` 拉索引和包。国内直连时 `moon update` 与 `moon install` 都会拖，装一次 bm2 要等好几分钟。

配一个镜像能把包下载提速一倍以上。索引仍然建议留在官方，原因下面说。

## 配置写在哪

`~/.moon/config.json`，文件不存在就新建。

推荐内容：

```json
{
  "registry": "https://mooncakes.io/",
  "download": "https://mirrors.ustc.edu.cn/mooncakes",
  "index": "https://mooncakes.io/git/index",
  "api": "https://mooncakes.io",
  "symbols": "https://mirrors.ustc.edu.cn/mooncakes/symbols.zip"
}
```

五个字段各自管一件事：

- `registry` 是 mooncakes 站点本身，留着官方默认值。
- `download` 是包 zip 的下载前缀，换成镜像地址就快了。
- `index` 是包索引的 git 仓库，决定「能装到哪些版本」。
- `api` 是站点接口，留着官方默认值。
- `symbols` 是索引符号包，可换镜像。

`registry` 这个字段不能省。实测只写 `download`、`index`、`symbols` 三个字段，moon 会直接抛内部错误并终止，连报错信息都不给具体原因。完整的官方默认值只有三个字段：

```json
{
  "registry": "https://mooncakes.io/",
  "index": "https://mooncakes.io/git/index",
  "symbols": "https://mooncakes.io/symbols.zip"
}
```

## 为什么 index 不跟着换

中科大镜像的包体是新的，但它的 git 索引会落后一段时间。索引决定 moon 认不认得某个版本，落后就会这样：

```
Error: No description found for version 0.7.1 in index file
"/root/.moon/registry/index/user/chensuiyi/bm2.index"
```

包明明已经同步到镜像上了，索引里却只有 `0.6.0`，于是装 `0.7.1` 直接失败。

所以分工是：`index` 用官方，`download` 用镜像。索引很小，慢一点无所谓，包体大，走镜像收益明显。

## 实测对比

本机 Debian on WSL，每次跑之前清掉 `~/.moon/registry/index`、`cache`、`symbols` 和构建缓存，按冷启动计。

| 来源 | `moon update` | 包下载速度 | 能装到的 bm2 |
| --- | --- | --- | --- |
| 官方 index | 3.6s | 3.74 MB/s | `0.7.1` |
| USTC index | 1.7s | 7.92 MB/s | `0.6.0` |

速度是网络环境的快照，你机器上的绝对值会不一样，比例大致就是这个量级。

## 两个别踩的坑

不要设 `MOONCAKES_REGISTRY` 环境变量到 `mooncakes.moonbitlang.cn`。这个域名不存在，DNS 直接返回 NXDOMAIN，而且报错会指向 registry 而不是环境变量，很难看出是谁改的。

`cli.moonbitlang.cn` 也没有加速。它只是 302 跳到 `cli.moonbitlang.com`，多一次跳转而已。

## symbols.zip 的已知问题

上游 `https://mooncakes.io/symbols.zip` 目前返回的是一个 HTML 页面，不是 zip。moon 对这件事只记一条警告，不影响装包。介意日志里有这条警告，就把 `symbols` 指向镜像。

## 改回官方

把 `~/.moon/config.json` 换成上面那份三字段的官方默认值即可。想彻底清干净，连同 `~/.moon/registry` 一起删掉，下次 `moon update` 会重新拉。
