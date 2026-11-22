///|
/// The command surface: what `bm2 help` prints, one function per line of it.
///
/// Help is about the tool, not about a project, so it follows the operator's own
/// environment rather than any project's `lang` — the same reasoning as the CLI's
/// error messages.
///
/// The English column is the text bm2 already printed; it is the contract.

///|
pub fn help_root(lang : Lang) -> String {
  match lang {
    En => "Process manager for Bun / Node.js on Linux"
    Zh => "Linux 上的 Bun / Node.js 进程管理器"
  }
}

///|
pub fn help_start(lang : Lang) -> String {
  match lang {
    En => "Start the project; reads ./bm2.toml or the given config path"
    Zh =>
      "启动项目;默认读当前目录的 bm2.toml,也可指定配置路径"
  }
}

///|
pub fn help_restart(lang : Lang) -> String {
  match lang {
    En => "Stop and start again, re-reading the config"
    Zh => "停掉再起一次,并重新读取配置"
  }
}

///|
pub fn help_stop(lang : Lang) -> String {
  match lang {
    En => "Stop a project, leaving it registered and stopped"
    Zh => "停止项目,保留注册状态与停止标记"
  }
}

///|
pub fn help_delete(lang : Lang) -> String {
  match lang {
    En => "Delete a project: stop it, free its name, keep its logs"
    Zh => "删除项目,停止它,释放名字,保留日志"
  }
}

///|
pub fn help_force(lang : Lang) -> String {
  match lang {
    En => "Also delete its state directory, logs included"
    Zh => "连同它的状态目录一起删除,日志也在内"
  }
}

///|
pub fn help_kill(lang : Lang) -> String {
  match lang {
    En => "Stop and unregister a project"
    Zh => "停止并注销一个项目"
  }
}

///|
pub fn help_all(lang : Lang) -> String {
  match lang {
    En => "Stop bm2d and all apps (skip confirmation)"
    Zh => "停止 bm2d 与全部应用(跳过确认)"
  }
}

///|
pub fn help_list(lang : Lang) -> String {
  match lang {
    En => "Show project status"
    Zh => "查看项目状态"
  }
}

///|
pub fn help_json(lang : Lang) -> String {
  match lang {
    En => "Machine-readable JSON output"
    Zh => "机器可读的 JSON 输出"
  }
}

///|
pub fn help_check(lang : Lang) -> String {
  match lang {
    En => "Validate the bm2.toml in the current directory"
    Zh => "校验当前目录下的 bm2.toml"
  }
}

///|
pub fn help_reload(lang : Lang) -> String {
  match lang {
    En => "Restart the daemon with a new binary; apps keep running"
    Zh => "用新二进制重启守护进程,应用照常运行"
  }
}

///|
pub fn help_notify(lang : Lang) -> String {
  match lang {
    En => "Send a test message to notification targets"
    Zh => "给通知目标发一条测试消息"
  }
}

///|
pub fn help_clean(lang : Lang) -> String {
  match lang {
    En => "Remove ownerless project directories from the state dir"
    Zh => "清理状态目录里无主的项目目录"
  }
}

///|
pub fn help_dry_run(lang : Lang) -> String {
  match lang {
    En => "Only list what would be removed"
    Zh => "只列出会被删除的内容"
  }
}

///|
pub fn help_upgrade(lang : Lang) -> String {
  match lang {
    En => "Upgrade bm2 and apply it seamlessly"
    Zh => "升级 bm2 并无缝切换"
  }
}

///|
pub fn help_version(lang : Lang) -> String {
  match lang {
    En => "Show version"
    Zh => "显示版本"
  }
}

///|
pub fn arg_project_to_stop(lang : Lang) -> String {
  match lang {
    En => "Project to stop"
    Zh => "要停止的项目"
  }
}

///|
pub fn arg_project_to_delete(lang : Lang) -> String {
  match lang {
    En => "Project to delete"
    Zh => "要删除的项目"
  }
}

///|
/// `start` 的位置参数是配置文件路径，不是项目名：启动必须有配置来源。
pub fn arg_config_path(lang : Lang) -> String {
  match lang {
    En => "Config path, defaults to ./bm2.toml"
    Zh => "配置文件路径,默认当前目录的 bm2.toml"
  }
}

///|
/// `kill` / `list` narrow their answer to a project; `notify` sends to every
/// configured target, so it takes no positional argument.
pub fn arg_limit_to_project(lang : Lang) -> String {
  match lang {
    En => "Limit to this project"
    Zh => "只针对这个项目"
  }
}

///|
pub fn kill_needs_confirmation(lang : Lang) -> String {
  match lang {
    En => "refusing to stop bm2d and all apps; use 'bm2 kill -y' to confirm"
    Zh => "拒绝停止 bm2d 与全部应用,请用 'bm2 kill -y' 确认"
  }
}

///|
pub fn cannot_determine_cwd(lang : Lang) -> String {
  match lang {
    En => "cannot determine current directory"
    Zh => "无法确定当前目录"
  }
}
