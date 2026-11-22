///|
/// Bytes in a megabyte: the configured size is in megabytes, the rotation
/// compares it against a byte count.
const MIB : Int64 = 1024L * 1024L

///|
/// How often collected logs are flushed into the project log files. One second is
/// slow enough to batch a burst and fast enough that `bm2 logs -f` reads like
/// live output.
const COLLECT_INTERVAL_MS : UInt64 = 1000UL

///|
/// How often the daemon's own logs (event logs, stderr) are checked for size.
/// They are far lower-traffic than app output, and rotating them copies bytes,
/// so this runs on its own slower clock.
const LOG_CHECK_INTERVAL_MS : UInt64 = 10000UL

///|
/// How often stale date files are pruned: once a minute is plenty for a
/// directory scan per project.
const PRUNE_EVERY_ROUNDS : Int32 = 60

///|
/// 项目目录：状态、暂存、日志都在这里，和 bm2 自己的文件分开。
pub fn project_dir(state_dir : String, name : String) -> String {
  @utils.join_path(@utils.join_path(state_dir, "projects"), name)
}

///|
/// 项目的成品日志目录：`logs/<项目>-<日期>[.error][.<片>].log`。
pub fn project_logs_dir(state_dir : String, name : String) -> String {
  @utils.join_path(project_dir(state_dir, name), "logs")
}

///|
/// 实例运行状态目录：`state/<实例号>.json`。状态是 daemon 自己重启后认领实例
/// 的依据，和注册信息（`project.json`）、日志分开三个位置，谁的职责一眼可见。
pub fn project_state_dir(state_dir : String, name : String) -> String {
  @utils.join_path(project_dir(state_dir, name), "state")
}

///|
/// 项目的实例暂存目录：应用直接把 stdout/stderr 写进这里，收集任务读走即清空。
pub fn project_staging_dir(state_dir : String, name : String) -> String {
  @utils.join_path(project_dir(state_dir, name), ".tempLogs")
}

///|
/// 本地日期（`2026-11-22`）：日志按天切分用的是人所在的那一天，不是 UTC。
/// 每日统计的整点判断也走本地时间，两处口径一致。
pub fn local_day(epoch_ms : UInt64) -> String {
  let parts = match @proc.local_parts(epoch_ms) {
    Some(parts) => parts
    None => return "1970-01-01"
  }
  let (year, month, day, _, _, _) = parts
  let pad = fn(n : Int32, width : Int32) {
    let text = n.to_string()
    let mut out = ""
    for _ in 0..<(width - text.length()) {
      out = out + "0"
    }
    out + text
  }
  pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
}

///|
/// 一个项目这一轮要收集什么。纯字符串与数字，tick 里构造不碰文件系统。
pub(all) struct LogTask {
  name : String
  staging_dir : String
  logs_dir : String
  max_bytes : Int64
  keep_files : Int32
}

///|
/// Publish one collection round: every project's staging directory, its log
/// directory, and its own `[logs]` policy.
///
/// The daemon's own event logs are not part of this: they belong to no project,
/// have no app writing into them, and keep the older size-only rotation.
fn Supervisor::publish_log_tasks(self : Supervisor) -> Unit {
  let tasks : Array[LogTask] = []
  for pair in self.projects.iter() {
    let (name, _) = pair
    let policy = match self.config_of(name) {
      Some(app) => app.logs
      None => @config.LogsConfig::builtin()
    }
    tasks.push({
      name,
      staging_dir: project_staging_dir(self.state_dir, name),
      logs_dir: project_logs_dir(self.state_dir, name),
      max_bytes: policy.max_size_mb.to_int64() * MIB,
      keep_files: policy.keep_files,
    })
  }
  if tasks.length() == 0 {
    return
  }
  @utils.discard(() => ignore(self.log_tasks.try_put(tasks)))
}

///|
/// Ask the rotation task to sweep the daemon's own logs: the two event logs are
/// written by us (rename is enough), the daemon stderr is held open by the daemon
/// itself (copytruncate).
fn Supervisor::publish_daemon_rotation(self : Supervisor) -> Unit {
  let builtin = @config.LogsConfig::builtin()
  let max_bytes = builtin.max_size_mb.to_int64() * MIB
  let jobs : Array[@log.RotateJob] = []
  for
    suffix in [
      ("bm2d.events.log", false),
      ("bm2.events.log", false),
      ("bm2d.log", true),
    ] {
    let (name, copytruncate) = suffix
    jobs.push({
      path: @utils.join_path(self.state_dir, name),
      copytruncate,
      max_bytes,
      keep: 7,
    })
  }
  @utils.discard(() => ignore(self.rotations.try_put(jobs)))
}

///|
/// 记一条 bm2 自己的日志行：写进该项目的 `<项目>-bm2.err.log` 暂存，
/// 收集时自动带上 `[bm2] ` 前缀进错误日志。
///
/// 走暂存而不是直接写主日志，是为了顺序：应用崩溃前最后几行还在它自己的
/// 暂存里，同一条收集链路沿用同一批文件，不会出现「崩溃记录跑到最后输出前面」。
fn Supervisor::write_daemon_log(
  self : Supervisor,
  app_name : String,
  line : String,
) -> Unit {
  let staging = project_staging_dir(self.state_dir, app_name)
  // crash 记录可能发生在 spawn 之前（拉起就失败），暂存目录还没建过。
  @utils.discard(() => @fsx.mkdir_p(staging, mode=0o700))
  let path = @utils.join_path(staging, app_name + "-bm2.err.log")
  // 写裸文本，时间戳与前缀由收集任务统一加：@log.plain 会自己带一个时间戳，
  // 叠加之后就是「时间 [bm2] 时间 内容」的重复。
  @utils.discard(() => @fsx.append_file(path, @utf8.encode(line + "\n")))
}

///|
/// Append one line to the project's error log, through the staging file: the
/// operator's only record of why an instance was restarted or parked in errored,
/// so it stays a plain text line rather than a nested structure.
fn Supervisor::write_crash(
  self : Supervisor,
  inst : Instance,
  reason : String,
) -> Unit {
  let buf = StringBuilder()
  buf.write_string("实例 " + inst.instance_id.to_string())
  buf.write_string(" pid=" + inst.pid.to_string())
  buf.write_string(" 原因=" + reason)
  if inst.last_exit_code is Some(code) {
    buf.write_string(" 退出码=" + code.to_string())
  }
  if inst.last_signal is Some(sig) {
    buf.write_string(" 信号=" + signal_name(sig))
  }
  if reason == "memory_limit" {
    buf.write_string(" 内存=" + (inst.last_rss_kb / 1024).to_string() + "MB")
    let limit = match self.config_of(inst.app_name) {
      Some(app) => app.max_memory_mb.to_string()
      None => "-"
    }
    buf.write_string(" 上限=" + limit + "MB")
  }
  buf.write_string(" 重启次数=" + inst.restart_count.to_string())
  self.write_daemon_log(inst.app_name, buf.to_string())
}
