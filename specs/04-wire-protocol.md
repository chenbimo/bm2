# 04 · CLI ↔ 守护进程线协议

- 状态: active
- 覆盖测试: `src/core/core_test.mbt`(版本携带与失配)、e2e 段 A 与失配段
- 与代码对账: 2026-10-13

## 传输

loopback TCP,加一个共享令牌。端点写在 `<state_dir>/daemon.endpoint`:第一行端口、第二行令牌,原子替换,权限 0600。客户端读一次、用同一个端点代次的两半,避免跨代混用。

帧是长度前缀。命令带应用名时,app 字段是**名字**,不是路径——客户端不传状态目录,守护进程自己知道。

## Request

```
Request {
  protocol : Int32?        // 当前 PROTOCOL_VERSION = 4
  command : String
  app : String?
  config_path : String?    // start / notify 用
  notify_target : String?
  force : Bool?            // remove 用
}
```

`protocol` 是可选字段,这样早于版本化的对端仍能解码,失配按名字报出来而不是变成一个无法解释的解码失败。

## 升版规则

`PROTOCOL_VERSION` 在这两种情况下必须升:

1. 对端**读不懂**——新增字段或新动词会让老守护进程拒绝请求
2. **含义变了**——字段仍能被解析,但老端的处理与新端不同(例如 `force` 被静默忽略,要求强杀的一方却得到优雅停止)

第二种比第一种危险,因为它不报错。版本不匹配时 CLI 给出的是可操作的一句话:提示运行 `bm2 reload`。

## 队列与超时

- 命令队列容量 64:一条命令占一个 tick,调用方同时只有一条在飞
- 应答队列容量 1:调用方放弃等待只丢应答,不影响守护进程
- 等待应答上限 15 s;命令行侧按项目的 `stop_timeout` 计算更大的值(一次完整重启要等得起)

## 应答

`Response` 带 `protocol`、`ok` 与结果负载(list 时含实例数组与守护进程信息)。协议问题单独判:`protocol_problem` 一旦有值,CLI 先报它,不再解释后续内容。
