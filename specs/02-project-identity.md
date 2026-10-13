# 02 · 项目身份与状态目录

- 状态: active
- 覆盖测试: `src/core/supervisor_wbtest.mbt`(同名保护、注销无残留)、`src/fsx/fsx_wbtest.mbt`(realpath)、e2e 段 S / V
- 与代码对账: 2026-10-13

## 一个 bm2.toml 管一个项目

`bm2.toml` 在项目目录里,配置单个应用(一到多个实例)。CLI 读的是**当前目录**的那一份。

项目名规则:`[A-Za-z][A-Za-z0-9_]*`;在所有已注册项目中必须唯一。

## 身份 = 名字 + 规范化的配置路径

名字是身份的主体:状态目录、日志、监督策略、通知配置全部挂在它上面。因此**同名但不同配置文件必须拒绝启动**,错误信息要点名占用者的路径。

判据用的是规范化后的真实路径(`realpath`),所以同一个文件经由软链、`..` 或相对路径到达时仍算同一个项目——同一个项目重新 `start` 应用配置变更必须继续放行。

拒绝时给出两条出路:改名字,或先 `bm2 remove` 掉占用的那个。

## 状态目录布局

`<state_dir>` 默认 `$HOME/.bm2`(启动时校验目录归属)。一个项目一个目录:

```
<state_dir>/
  bm2d.events.jsonl bm2.events.jsonl bm2d.log   # 守护进程自身,不属任何项目
  daemon.endpoint                                # 端口 + 令牌,原子替换,0600
  <name>/
    project.json          # 登记记录:config_path + stopped
    <name>-<id>.json      # 每个实例的状态,恢复时用于收养
    logs/                 # 见 06
```

## 项目是一个值

一个项目的全部状态装在 `Project` 里,以名字为键的表只有 `projects` 一张。新增项目级状态就是给 `Project` 加字段——不是新开一张表加一处注销。

这不是审美:散落的表会让「注销」变成一件必须记得很多次的事,而人一定会忘。本轮就漏过一次(`config_paths` 从未被清除),后果是静默的跨项目串味——重名再注册时拿旧路径去比对。

## 注销只有一个出口

`Supervisor::forget_app` 是释放项目状态的唯一地方。`check_removals` 只调它一次,不自己清表。

`project.json` 的字段目前是 `config_path` 与 `stopped`。项目还没有外部使用者,格式变更可以直接不兼容,不需要迁移代码。
