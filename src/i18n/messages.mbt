///|
/// The messages a person reads, one function per message.
///
/// Written as a `match` on the language rather than a lookup table, so a new
/// language is a compile-time walk over every message: the build refuses to
/// finish until each one answers, which is exactly the guarantee a keyed table
/// cannot give.
///
/// The English text is the text bm2 already printed before this existed. Tests
/// assert it, so it is the contract, not a translation of one.

///|
pub fn started(lang : Lang) -> String {
  match lang {
    En => "started"
    Zh => "已启动"
  }
}

///|
pub fn stopped(lang : Lang) -> String {
  match lang {
    En => "stopped"
    Zh => "已停止"
  }
}

///|
/// 退役中:项目已经停下,正在从名册里退出。
pub fn removing(lang : Lang) -> String {
  match lang {
    En => "removing"
    Zh => "正在退役"
  }
}

///|
pub fn reloading(lang : Lang) -> String {
  match lang {
    En => "reloading"
    Zh => "正在重启守护进程"
  }
}

///|
pub fn reloaded(lang : Lang) -> String {
  match lang {
    En => "reloaded"
    Zh => "守护进程已重启"
  }
}

///|
pub fn bm2d_stopping(lang : Lang) -> String {
  match lang {
    En => "bm2d stopping"
    Zh => "bm2d 正在退出"
  }
}

///|
pub fn no_instances(lang : Lang) -> String {
  match lang {
    En => "no instances"
    Zh => "没有实例"
  }
}

///|
/// 命令名不翻译:`stop` 是你要敲的字,不是要读的词。
pub fn stop_requires_name(lang : Lang) -> String {
  match lang {
    En => "stop requires a project name"
    Zh => "stop 需要一个项目名"
  }
}

///|
pub fn remove_requires_name(lang : Lang) -> String {
  match lang {
    En => "remove requires a project name"
    Zh => "remove 需要一个项目名"
  }
}

///|
pub fn start_requires_config_path(lang : Lang) -> String {
  match lang {
    En => "start requires a config path"
    Zh => "start 需要一个配置路径"
  }
}

///|
pub fn unknown_command(lang : Lang, command : String) -> String {
  match lang {
    En => "unknown command: " + command
    Zh => "未知命令:" + command
  }
}

///|
/// `bm2d`'s own lines: the daemon's startup complaints, its answers to commands
/// that never made it into a project context, and the `bm2 dev` follow banner.
///
/// The daemon's startup lines follow the daemon's own environment; everything it
/// answers follows the request's language.

///|
pub fn bm2d_usage(lang : Lang) -> String {
  match lang {
    En => "usage: bm2d"
    Zh => "用法: bm2d"
  }
}

///|
pub fn bm2d_already_running(lang : Lang) -> String {
  match lang {
    En => "bm2d: another daemon is already running"
    Zh => "bm2d: 已经有一个守护进程在运行"
  }
}

///|
pub fn bm2d_no_token(lang : Lang) -> String {
  match lang {
    En => "bm2d: cannot generate the access token"
    Zh => "bm2d: 无法生成访问令牌"
  }
}

///|
pub fn bm2d_no_control_file(lang : Lang) -> String {
  match lang {
    En => "bm2d: cannot write the control-plane file"
    Zh => "bm2d: 无法写入控制面文件"
  }
}

///|
/// The caller waited and the daemon is simply busy: the command queue is deep, so
/// the advice is "try again", not "something is broken".
pub fn daemon_busy(lang : Lang, timeout_ms : Int32) -> String {
  match lang {
    En =>
      "bm2d is running but did not answer within \{timeout_ms}ms; try again in a moment"
    Zh =>
      "bm2d 正在运行,但在 \{timeout_ms}ms 内没有响应,请稍后再试"
  }
}

///|
pub fn invalid_request(lang : Lang) -> String {
  match lang {
    En => "invalid request"
    Zh => "请求不合法"
  }
}

///|
pub fn too_many_requests(lang : Lang) -> String {
  match lang {
    En => "too many control requests in flight"
    Zh => "在途的控制请求过多"
  }
}

///|
pub fn notify_requires_config(lang : Lang) -> String {
  match lang {
    En => "notify requires a config path"
    Zh => "notify 需要一个配置路径"
  }
}

///|
pub fn notify_delivery_timeout(lang : Lang) -> String {
  match lang {
    En => "the notify task did not report a result within the delivery timeout"
    Zh => "通知任务没有在投递超时内返回结果"
  }
}

///|
pub fn unknown_notify_target(lang : Lang, name : String) -> String {
  match lang {
    En => "unknown notification target: " + name
    Zh => "未知的通知目标:" + name
  }
}

///|
pub fn no_notify_targets(lang : Lang) -> String {
  match lang {
    En => "no notification targets configured"
    Zh => "没有配置通知目标"
  }
}

///|
/// Refusing a test delivery to a project that turned notifications off: name the
/// two things to change, so the answer is a fix rather than a lookup.
pub fn notify_not_enabled(lang : Lang, app : String) -> String {
  match lang {
    En =>
      "project " +
      app +
      " has no notifications enabled: set [notify].enabled = true and add at least one [[notify.report.target]] in bm2.toml"
    Zh =>
      "项目 " +
      app +
      " 没有启用通知:请在 bm2.toml 里设置 [notify].enabled = true,并至少添加一个 [[notify.report.target]]"
  }
}

///|
/// The first line of a `bm2 dev` follow session, printed before any log line: it
/// says what the command is doing and how to stop the app, because ctrl-c only
/// stops the following.
pub fn follow_started(lang : Lang, name : String) -> String {
  match lang {
    En =>
      "bm2 dev: following logs. ctrl-c stops following; the app keeps running ('bm2 stop \{name}')\n"
    Zh =>
      "bm2 dev: 正在跟随日志。ctrl-c 只停止跟随,应用继续运行('bm2 stop \{name}')\n"
  }
}

///|
pub fn follow_stopped(lang : Lang, name : String) -> String {
  match lang {
    En =>
      "\nbm2 dev: stopped following (the app keeps running: 'bm2 stop \{name}')\n"
    Zh => "\nbm2 dev: 已停止跟随(应用继续运行:'bm2 stop \{name}')\n"
  }
}

///|
pub fn follow_gone(lang : Lang, name : String) -> String {
  match lang {
    En => "bm2 dev: \{name} is no longer registered; stopped following\n"
    Zh => "bm2 dev: \{name} 已不在名册中,停止跟随\n"
  }
}

///|
/// The body of the test message `bm2 notify` sends: it says what it is, because
/// it arrives in a chat group among real alerts.
pub fn notify_test_title(lang : Lang) -> String {
  match lang {
    En => "bm2 notification test"
    Zh => "bm2 通知测试"
  }
}

///|
pub fn notify_test_body(lang : Lang) -> String {
  match lang {
    En =>
      "If you see this message, the notification target is configured correctly."
    Zh => "能看到这条消息,说明这个通知目标配置正常。"
  }
}

///|
/// One line per target in `bm2 notify`'s answer: the target's name, then what
/// happened. The name is an operator's own label, so it never translates.
pub fn notify_target_sent(lang : Lang, name : String) -> String {
  match lang {
    En => name + ": sent"
    Zh => name + ": 已发送"
  }
}

///|
/// The failure line. The reason is whatever the transport said, and that is not
/// ours to reword, so only the word around it is translated.
pub fn notify_target_failed(
  lang : Lang,
  name : String,
  reason : String,
) -> String {
  match lang {
    En => name + ": failed - " + reason
    Zh => name + ": 失败 - " + reason
  }
}
