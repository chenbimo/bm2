///|
/// The housekeeping task: the only place that copies, renames, truncates or
/// appends log bytes on behalf of supervision.
///
/// Two jobs on two clocks:
///
/// - **收集**（每秒）：把每个项目各实例的暂存日志搬进项目日志（`.tempLogs` →
///   `logs/<项目>-<日期>[.error][.<片>].log`）。tick 只发布「哪个项目、哪个
///   目录、什么策略」这份清单。
/// - **daemon 日志轮转**（每十秒，跟发布节奏一致）：bm2 自己的两份事件日志与
///   自己的 stderr，流量低，按大小轮转即可。
///
/// 两者都在这里做，是因为它们都要碰文件系统：一次十兆的搬运或拷贝在慢盘上
/// 足够拖住每一个 deadline，而 tick 里不允许有这种等待。

///|
pub struct RotateRunner {
  /// Daemon log rotation sweeps published every ten seconds.
  inbound : @aqueue.Queue[Array[@log.RotateJob]]
  /// Per-project collection rounds published every second.
  collects : @aqueue.Queue[Array[LogTask]]
  state_dir : String
  /// 第几轮，用于把目录清理摊到每分钟一次。
  mut rounds : Int32
}

///|
pub fn RotateRunner::new(
  state_dir : String,
  inbound : @aqueue.Queue[Array[@log.RotateJob]],
  collects : @aqueue.Queue[Array[LogTask]],
) -> RotateRunner {
  { inbound, collects, state_dir, rounds: 0, }
}

///|
/// Sweep one published list: rotate every daemon log that is over its limit, and
/// record what happened. Outcomes are events only, never supervision state.
async fn RotateRunner::sweep(
  self : RotateRunner,
  jobs : Array[@log.RotateJob],
) -> Unit {
  for job in jobs {
    match @log.maybe_rotate_async(job) {
      Skipped => ()
      Rotated =>
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "log_rotated",
          detail=job.path,
        )
      Failed(reason) =>
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "log_rotate_failed",
          detail=job.path + ": " + reason,
        )
    }
  }
}

///|
/// 一轮收集：每个项目的两条流各搬一次，顺带每分钟清理一次过期日期文件。
async fn RotateRunner::collect(
  self : RotateRunner,
  tasks : Array[LogTask],
) -> Unit {
  let today = local_day(@utils.now_ms())
  let prune_now = self.rounds % PRUNE_EVERY_ROUNDS == 0
  for task in tasks {
    let normal = @log.LogStream::new(
      task.logs_dir,
      task.name,
      "",
      task.max_bytes,
      task.keep_days,
    )
    let error = @log.LogStream::new(
      task.logs_dir,
      task.name,
      ".error",
      task.max_bytes,
      task.keep_days,
    )
    let result = @log.drain_project(
      task.staging_dir,
      task.name,
      normal,
      error,
      today,
    )
    if result.dropped_bytes > 0 {
      log_event(
        self.state_dir,
        "bm2d.events.jsonl",
        "log_dropped",
        app=Some(task.name),
        detail=result.dropped_bytes.to_string() + " bytes",
      )
    }
    if prune_now {
      normal.prune()
      error.prune()
    }
  }
  self.rounds += 1
}

///|
/// 每秒一拍：收集项目日志，顺手看一眼 daemon 日志该不该轮转。
///
/// 用固定节奏而不是等队列，是因为收集本身就有时间语义（「一秒内的输出」），
/// 而队列只在有变化时才来消息。取不到清单就跳过这一轮，不做任何事。
pub async fn RotateRunner::run(self : RotateRunner) -> Unit {
  while true {
    let timer = @async.Timer::Timer(COLLECT_INTERVAL_MS.to_int())
    timer.wait()
    let tasks = try self.collects.try_get() catch {
      _ => None
    } noraise {
      items => items
    }
    match tasks {
      Some(list) => self.collect(list)
      None => ()
    }
    let jobs = try self.inbound.try_get() catch {
      _ => None
    } noraise {
      items => items
    }
    match jobs {
      Some(list) => self.sweep(list)
      None => ()
    }
  }
}
