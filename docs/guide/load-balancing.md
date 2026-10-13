# 负载均衡

## cluster 模式（默认）

```toml
exec_mode = "cluster"   # 可以省略，默认即 cluster
instances = 4
port = 3000
```

所有实例共享同一个端口。它基于 Linux 的 `SO_REUSEPORT`：每个实例监听同一端口，内核按连接四元组哈希分发，因此不需要网关就能做到单端口多副本负载均衡。要求 bun >= 1.4.0 或 node >= 24.0.0。

应用侧监听时必须打开 `reusePort`：

```js
const PORT = Number(process.env.BM2_APP_PORT);

// Bun
Bun.serve({ port: PORT, reusePort: true, fetch: () => new Response("ok") });

// Node.js
const http = require("node:http");
http.createServer((req, res) => res.end("ok")).listen({ port: PORT, reusePort: true });
```

开启 `reusePort` 是应用的责任，因为只有它知道自己的监听方式。bm2 在启动后实测这一点：如果没开，**整个项目会被停止**，所有实例进入 `errored`，原因记为 `reuseport_missing`。修正应用后重新 `bm2 start` 即可，注册不会丢。

单个实例崩溃后自动重启并重新加入端口组，其余实例不受影响。`BM2_APP_INSTANCE === "0"` 的主实例判断在 cluster 模式下同样可用。

## fork 模式

```toml
exec_mode = "fork"
instances = 3
port = 3000
```

端口从 `port` 起连续分配：`3000`、`3001`、`3002`。分发交给网关。

实例增减之后要同步更新 upstream 列表并 reload 网关——这是 fork 模式要求你做的那部分工作。

Nginx 示例（假设 `instances = 2`、`port = 3000`）：

```nginx
upstream bm2_app {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
}

server {
    listen 80;
    server_name example.com;

    location / {
        proxy_pass http://bm2_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy 示例：

```text
example.com {
    reverse_proxy 127.0.0.1:3000 127.0.0.1:3001
}
```

## 网关与 bm2 的分工

bm2 只做进程托管，反向代理与负载均衡交给网关。两者的分界很清楚：

- **cluster 模式**：bm2 自己就是负载均衡层，网关只需要一条 `server 127.0.0.1:3000;`。实例增减不需要动网关配置。
- **fork 模式**：bm2 提供连续端口，网关负责分发，实例增减要更新 upstream。

需要域名、TLS 或跨机分发时，两种模式都要配网关——那时网关解决的是 bm2 不打算解决的问题。
