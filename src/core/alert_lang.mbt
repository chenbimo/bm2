///|
/// Notification copy, centralized: every message bm2 renders is one variant
/// of `Bm2Msg`, turned into (title, body) by `render_msg` in the project's
/// configured language. CLI output, the event log and JSON payloads stay
/// language-neutral by design — only what a human reads in a chat group is
/// translated.

///|
/// True for the Chinese copy. One place decides what counts as Chinese, so the
/// rendering sites cannot drift apart — `[notify] lang` validation already
/// restricts the value to "en" / "zh".
fn is_zh(lang : String) -> Bool {
  lang == "zh"
}

///|
/// All notification messages bm2 can render.
pub enum Bm2Msg {
  ProjectStarted(Int32, String, Int32)
  ProjectStopped(String)
  ProjectKilled(String)
  CleanExitRestarting
  CrashRestarting(String, Int32, Int32)
  SpawnFailedRetrying(Int32, Int32)
  ErroredStopped(String, Int32, Int32)
  ErroredSpawnStopped(Int32, Int32)
  MemoryLimit(Int32, Int32)
  ReuseportMissing(String, Int32)
  ThresholdRestarts(Int32, Int32)
  ThresholdOffline(String, Int32)
  ThresholdMemory(Int32, Int32, Int32)
  RestartStorm(Int32, Int32)
  OomKill(String, Int32, Int32, Int32)
  DiskPressure(Int32, Int32)
  StartTimeout(Int32, Int32)
  HealthReport(String, Bool)
  StatsReport(String)
  DaemonAdopted(Int32)
}

///|
/// Turn a message into (title, body) in the given language. Unknown
/// languages fall back to English, matching the `[notify] lang` validation.
pub fn render_msg(lang : String, msg : Bm2Msg) -> (String, String) {
  if is_zh(lang) {
    render_zh(msg)
  } else {
    render_en(msg)
  }
}

///|
fn render_en(msg : Bm2Msg) -> (String, String) {
  match msg {
    ProjectStarted(instances, mode, port) =>
      (
        "Project started",
        "Started \{instances} instance(s) as configured (\{mode} mode, port \{port}).",
      )
    ProjectStopped(app) =>
      (
        "Project stopped",
        "Project \{app} stopped as requested; registration kept — run bm2 start to launch it again.",
      )
    ProjectKilled(app) =>
      (
        "Project killed",
        "Project \{app} killed: instances stopped and the registration removed; bm2 list no longer shows it.",
      )
    CleanExitRestarting =>
      (
        "Clean exit, restarting automatically", "Process exited with code 0 after running beyond min_uptime; restarting per plan (crash budget not consumed).",
      )
    CrashRestarting(cause, count, budget) =>
      (
        "Abnormal exit, restarting automatically",
        "\{cause}; \{count}/\{budget} consecutive crashes; restarting with backoff.",
      )
    SpawnFailedRetrying(count, budget) =>
      (
        "Spawn failed, retrying",
        "\{count}/\{budget} consecutive failures; retrying with backoff.",
      )
    ErroredStopped(cause, count, budget) =>
      (
        "Auto-recovery stopped",
        "\{cause}; \{count} consecutive crashes, over the budget of \{budget}. Fix the issue and run bm2 start again.",
      )
    ErroredSpawnStopped(count, budget) =>
      (
        "Auto-recovery stopped",
        "Spawn failed; \{count} consecutive failures, over the budget of \{budget}. Check script, cwd and runtime availability.",
      )
    MemoryLimit(rss_mb, limit_mb) =>
      (
        "Memory limit exceeded, restarting",
        "RSS \{rss_mb}MB exceeds the limit of \{limit_mb}MB.",
      )
    ReuseportMissing(app, port) =>
      (
        "Cluster mode missing reusePort; project stopped",
        "Project \{app} listens on port \{port} in cluster mode without reusePort; to keep instances from racing for the port the project has been stopped. Add reusePort to the listener and run bm2 start again.",
      )
    ThresholdRestarts(count, threshold) =>
      (
        "Restarting too often",
        "Consecutive abnormal restarts \{count}, threshold \{threshold} reached.",
      )
    ThresholdOffline(status, minutes) =>
      (
        "Instance down for too long",
        "Instance has been \{status} for over \{minutes} minutes.",
      )
    ThresholdMemory(rss_mb, percent, limit_mb) =>
      (
        "Memory approaching limit",
        "RSS \{rss_mb}MB, which is \{percent}% of the \{limit_mb}MB limit.",
      )
    RestartStorm(count, threshold) =>
      (
        "Restart storm",
        "\{count} restarts within 10 minutes, threshold \{threshold} reached.",
      )
    OomKill(cause, limit_mb, count, budget) =>
      (
        "Killed by the kernel, restarting automatically",
        "\{cause}; the last RSS sample was at or above 90% of the \{limit_mb}MB limit, which points at the kernel OOM killer; \{count}/\{budget} consecutive crashes; restarting with backoff.",
      )
    DiskPressure(threshold_mb, free_gb) =>
      (
        "Disk space is running low",
        "The filesystem holding ~/.bm2 has less than \{threshold_mb}MB left (\{free_gb}GB free); state files and logs may fail to write.",
      )
    StartTimeout(port, timeout_ms) =>
      (
        "Port never started listening",
        "No listener on port \{port} within \{timeout_ms}ms of spawn; the app may be stuck before bind().",
      )
    HealthReport(app, empty) =>
      ("bm2 health report · \{app}", if empty { "No instances." } else { "" })
    StatsReport(app) => ("bm2 statistics · \{app}", "")
    DaemonAdopted(online) =>
      ("bm2d started", "Adopted this project: \{online} online instance(s).")
  }
}

///|
fn render_zh(msg : Bm2Msg) -> (String, String) {
  match msg {
    ProjectStarted(instances, mode, port) =>
      (
        "项目已启动",
        "已按配置启动 \{instances} 个实例（\{mode} 模式，端口 \{port}）。",
      )
    ProjectStopped(app) =>
      (
        "项目已停止",
        "项目 \{app} 已按需停止；注册保留——执行 bm2 start 可再次拉起。",
      )
    ProjectKilled(app) =>
      (
        "项目已注销",
        "项目 \{app} 已注销：实例停止且注册移除，bm2 list 不再显示。",
      )
    CleanExitRestarting =>
      (
        "干净退出，自动重启", "进程超过 min_uptime 后以 code 0 退出；按计划重启（不消耗崩溃预算）。",
      )
    CrashRestarting(cause, count, budget) =>
      (
        "异常退出，自动重启",
        "\{cause}；连续第 \{count}/\{budget} 次崩溃，退避后重启。",
      )
    SpawnFailedRetrying(count, budget) =>
      (
        "启动失败，重试中",
        "连续 \{count}/\{budget} 次启动失败；按退避重试。",
      )
    ErroredStopped(cause, count, budget) =>
      (
        "自动恢复已停止",
        "\{cause}；连续 \{count} 次崩溃，超出预算 \{budget}。请修复后执行 bm2 start。",
      )
    ErroredSpawnStopped(count, budget) =>
      (
        "自动恢复已停止",
        "启动失败；连续 \{count} 次超出预算 \{budget}。请检查脚本、cwd 与运行时可用性。",
      )
    MemoryLimit(rss_mb, limit_mb) =>
      (
        "内存超限，正在重启",
        "RSS \{rss_mb}MB 超过上限 \{limit_mb}MB。",
      )
    ReuseportMissing(app, port) =>
      (
        "cluster 缺少 reusePort，项目已停止",
        "项目 \{app} 以 cluster 模式监听 \{port} 端口但未开启 reusePort；为避免实例抢端口，项目已停止。开启后重新 bm2 start 即可。",
      )
    ThresholdRestarts(count, threshold) =>
      (
        "重启过于频繁",
        "连续异常重启 \{count} 次，达到阈值 \{threshold}。",
      )
    ThresholdOffline(status, minutes) =>
      (
        "实例离线过久",
        "实例已处于 \{status} 状态超过 \{minutes} 分钟。",
      )
    ThresholdMemory(rss_mb, percent, limit_mb) =>
      (
        "内存逼近上限",
        "RSS \{rss_mb}MB，已达 \{limit_mb}MB 上限的 \{percent}%。",
      )
    RestartStorm(count, threshold) =>
      (
        "重启风暴",
        "10 分钟内重启 \{count} 次，达到阈值 \{threshold}。",
      )
    OomKill(cause, limit_mb, count, budget) =>
      (
        "内核杀进程，自动重启",
        "\{cause}；最后采样 RSS 已达 \{limit_mb}MB 上限的 90% 以上，疑似内核 OOM killer；连续第 \{count}/\{budget} 次崩溃，退避后重启。",
      )
    DiskPressure(threshold_mb, free_gb) =>
      (
        "磁盘空间不足",
        "~/.bm2 所在文件系统剩余不足 \{threshold_mb}MB（当前 \{free_gb}GB）；状态文件与日志可能写入失败。",
      )
    StartTimeout(port, timeout_ms) =>
      (
        "端口始终未监听",
        "spawn 后 \{timeout_ms}ms 内端口 \{port} 仍无监听；应用可能卡在 bind 之前。",
      )
    HealthReport(app, empty) =>
      ("bm2 健康报告 · \{app}", if empty { "暂无实例。" } else { "" })
    StatsReport(app) => ("bm2 统计报告 · \{app}", "")
    DaemonAdopted(online) =>
      ("bm2d 已启动", "已接管本项目：\{online} 个实例在线。")
  }
}

///|
/// The cause sentence of crash-family notices, with the one cause worth
/// naming explicitly: a cluster port held exclusively by a foreign process.
pub fn crash_cause(
  lang : String,
  reason : String,
  detail : String,
  port_conflict : Bool,
) -> String {
  let mut text = if is_zh(lang) {
    "原因：\{reason}\{detail}"
  } else {
    "Cause: \{reason}\{detail}"
  }
  if port_conflict {
    let suffix = if is_zh(lang) {
      "；端口已被其他进程独占"
    } else {
      "; the port is held exclusively by another process"
    }
    text = text + suffix
  }
  text
}
