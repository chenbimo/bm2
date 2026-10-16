///|
/// What the CLI prints when a command succeeds or a step fails, other than the
/// daemon's own answers (those live in `messages.mbt`).
///
/// Everything here is about the operator's terminal, so the language is the
/// operator's, resolved once at startup.

///|
/// The daemon never came up. The log path is the useful part: it says where to
/// look, and it is a path, so only the sentence around it changes.
pub fn daemon_did_not_start(lang : Lang, state_dir : String) -> String {
  match lang {
    En => "bm2: bm2d did not start, see " + state_dir + "/bm2d.log"
    Zh => "bm2: bm2d 没有启动,见 " + state_dir + "/bm2d.log"
  }
}

///|
pub fn daemon_did_not_exit(lang : Lang) -> String {
  match lang {
    En => "bm2: bm2d did not exit; swap aborted"
    Zh => "bm2: bm2d 没有退出,放弃换班"
  }
}

///|
/// Printed by `remove -f` once the state directory is gone, and by `clean` for
/// each directory it sweeps.
pub fn removed(lang : Lang, what : String) -> String {
  match lang {
    En => "removed " + what
    Zh => "已删除 " + what
  }
}

///|
pub fn would_remove(lang : Lang, what : String) -> String {
  match lang {
    En => "would remove " + what
    Zh => "将会删除 " + what
  }
}

///|
pub fn left_in_place(lang : Lang, what : String) -> String {
  match lang {
    En => "bm2: left " + what + " in place: it holds files bm2 did not write"
    Zh => "bm2: 保留 " + what + ":里面有不是 bm2 写的文件"
  }
}

///|
/// `remove -f` waited for the daemon to let go of the project and it never did.
/// The files were kept on purpose: deleting them early would pull files out from
/// under a project the daemon still supervises.
pub fn retire_timeout(lang : Lang) -> String {
  match lang {
    En =>
      "bm2: the project did not finish retiring within the wait; its files were kept"
    Zh =>
      "bm2: 项目没有在等待时间内完成退役,它的文件已保留"
  }
}

///|
pub fn ownerless_summary(lang : Lang, count : Int32, dry_run : Bool) -> String {
  match lang {
    En =>
      if dry_run {
        "\{count} ownerless project directories listed, nothing removed"
      } else {
        "\{count} ownerless project directories removed"
      }
    Zh =>
      if dry_run {
        "列出 \{count} 个无主项目目录,未删除任何内容"
      } else {
        "已删除 \{count} 个无主项目目录"
      }
  }
}

///|
/// Appended to a start/kill answer when the target never reached its new state
/// inside the wait, so the message says what was asked for and this says why the
/// table below may still show the old one.
pub fn timed_out(lang : Lang) -> String {
  match lang {
    En => " (timed out waiting)"
    Zh => " (等待超时)"
  }
}

///|
/// Upgrade finished. The three forms differ in whether a running daemon was
/// already running the new binary.
pub fn updated(lang : Lang, applied~ : Bool) -> String {
  match lang {
    En => if applied { "updated and applied" } else { "updated" }
    Zh => if applied { "已升级并生效" } else { "已升级" }
  }
}

///|
pub fn update_needs_reload(lang : Lang) -> String {
  match lang {
    En => "updated; run 'bm2 reload' to apply"
    Zh => "已升级,执行 'bm2 reload' 生效"
  }
}

///|
/// Already newest: the version goes in the sentence because "up to date" without a
/// number is not a fact the operator can check.
pub fn update_up_to_date(lang : Lang, version : String) -> String {
  match lang {
    En => "bm2 is up to date (" + version + ")"
    Zh => "bm2 已是最新版本(" + version + ")"
  }
}

///|
pub fn update_available(
  lang : Lang,
  new_version : String,
  current : String,
) -> String {
  match lang {
    En => "new version " + new_version + " available (current " + current + ")"
    Zh => "有新版本 " + new_version + "(当前 " + current + ")"
  }
}

///|
pub fn upgrade_running(lang : Lang) -> String {
  match lang {
    En => "bm2: another upgrade is already running"
    Zh => "bm2: 另一个升级正在进行"
  }
}

///|
pub fn upgrade_unreachable(lang : Lang, base : String) -> String {
  match lang {
    En => "bm2: cannot reach the release station " + base
    Zh => "bm2: 无法访问发布站 " + base
  }
}

///|
pub fn upgrade_bad_manifest(lang : Lang) -> String {
  match lang {
    En => "bm2: cannot read the release manifest"
    Zh => "bm2: 无法读取发布清单"
  }
}

///|
pub fn upgrade_no_release(lang : Lang, target : String) -> String {
  match lang {
    En => "bm2: no release for " + target + " yet"
    Zh => "bm2: 还没有 " + target + " 的发布产物"
  }
}

///|
/// One download failed. The URL is included because it is the only thing that
/// says *which* artifact, and a partial update is not an update.
pub fn upgrade_download_failed(lang : Lang, url : String) -> String {
  match lang {
    En => "cannot download " + url
    Zh => "无法下载 " + url
  }
}

///|
pub fn upgrade_checksum_mismatch(lang : Lang, name : String) -> String {
  match lang {
    En => "checksum mismatch for " + name + "; update aborted"
    Zh => name + " 的校验和不匹配,已中止升级"
  }
}

///|
pub fn upgrade_not_executable(lang : Lang, name : String) -> String {
  match lang {
    En => "cannot mark " + name + " executable"
    Zh => "无法给 " + name + " 加上可执行权限"
  }
}

///|
pub fn upgrade_cannot_replace(lang : Lang, name : String) -> String {
  match lang {
    En => "cannot replace " + name
    Zh => "无法替换 " + name
  }
}

///|
/// The `list` table. Headers are labels, so they translate. The cells are
/// identifiers, so they translate only where they are words: `pid` reads the same
/// in both languages, `running` does not.
///
/// The JSON form of the same data is untouched, and so is any value bm2 does not
/// recognise — a status this build has never heard of prints as it came.

///|
pub fn list_headers(lang : Lang) -> Array[String] {
  match lang {
    En =>
      [
        "NAME", "ID", "PID", "PORT", "MODE", "EXEC", "STATUS", "TIMES", "MEMORY",
        "UPTIME", "CWD",
      ]
    Zh =>
      [
        "名称", "实例", "PID", "端口", "模式", "执行", "状态", "次数",
        "内存", "运行时长", "目录",
      ]
  }
}

///|
/// How the project was started: `development` for `bm2 dev`, `production` for
/// `bm2 serve`.
pub fn mode_value(lang : Lang, mode : String) -> String {
  match lang {
    En => mode
    Zh =>
      match mode {
        "development" => "开发"
        "production" => "生产"
        other => other
      }
  }
}

///|
/// How instances share the port.
pub fn exec_value(lang : Lang, exec_mode : String) -> String {
  match lang {
    En => exec_mode
    Zh =>
      match exec_mode {
        "cluster" => "集群"
        "fork" => "独立"
        other => other
      }
  }
}

///|
pub fn status_value(lang : Lang, status : String) -> String {
  match lang {
    En => status
    Zh =>
      match status {
        "running" => "运行中"
        "stopped" => "已停止"
        "starting" => "启动中"
        "stopping" => "停止中"
        "errored" => "出错"
        "restarting" => "重启中"
        other => other
      }
  }
}

///|
/// The daemon context line's labels, in the order they are printed. Eight
/// entries, one per column of the summary table; the labels are the header row
/// the renderer shows above the values. Mostly acronyms that read the same
/// everywhere, which is why this is a list of labels rather than a sentence:
/// there is no sentence to translate.
pub fn daemon_labels(lang : Lang) -> Array[String] {
  match lang {
    En =>
      [
        "pid", "fds", "rss", "uptime", "instances", "commands", "restarts", "removals",
      ]
    Zh =>
      [
        "pid", "fds", "rss", "运行时长", "实例", "命令", "重启", "退役",
      ]
  }
}

///|
pub fn check_ok(
  lang : Lang,
  name : String,
  instances : Int32,
  exec_mode : String,
  port : Int32,
  runtime : String,
) -> String {
  match lang {
    En =>
      "config ok: project \"\{name}\", \{instances} x \{exec_mode} on port \{port}, runtime \{runtime}"
    Zh =>
      "配置正常:项目 \"\{name}\",\{instances} 个\{exec_value(lang, exec_mode)}实例,端口 \{port},运行时 \{runtime}"
  }
}

///|
pub fn check_notify(
  lang : Lang,
  reports : Int32,
  targets : Int32,
  periodic : Int32,
) -> String {
  match lang {
    En =>
      "notify: \{reports} report(s), \{targets} target(s), \{periodic} periodic"
    Zh =>
      "通知:\{reports} 条规则,\{targets} 个目标,\{periodic} 条定时"
  }
}

///|
pub fn check_notify_disabled(lang : Lang) -> String {
  match lang {
    En => "notify: disabled"
    Zh => "通知:未启用"
  }
}

///|
pub fn check_ports_free(lang : Lang, first : Int32, last : Int32) -> String {
  match lang {
    En => "ports \{first}~\{last}: free"
    Zh => "端口 \{first}~\{last}:空闲"
  }
}

///|
/// Which kind of listener already holds a port. `shared` means the holder set
/// SO_REUSEPORT, so a cluster can join it; `exclusive` means it cannot.
pub fn port_holder_kind(lang : Lang, kind : String) -> String {
  match lang {
    En => kind
    Zh =>
      match kind {
        "shared" => "共享"
        "exclusive" => "独占"
        other => other
      }
  }
}

///|
pub fn check_port_held(lang : Lang, port : Int32, kind : String) -> String {
  match lang {
    En => "port \{port}: already held by a \{kind} listener"
    Zh => "端口 \{port}:已被一个\{kind}监听占用"
  }
}

///|
/// Emitted by the pre-start cross-check: the config parses, but the script it
/// names is not there, and starting anyway would only buy a crash-retry loop.
pub fn check_script_missing(lang : Lang, path : String) -> String {
  match lang {
    En => "script not found: " + path
    Zh => "找不到脚本:" + path
  }
}
