///|
/// 自升级:只走 `moon install` 一条路。
///
/// 初次安装有两条路——`moon install`,或从 GitHub Release 下载产物自己放进 PATH;
/// 升级只有这一条:查 registry 的最新版本 → `moon install` 覆盖当前目录的两个二进制
/// → 守护进程换班。
///
/// 换班不是重启:旧守护进程 detach 后退出,新守护进程用 pidfd 收养仍在运行的实例,
/// 应用 PID 不变、服务不中断。启动期的参数(环境变量白名单、端口)要等应用下次拉起
/// 才走新逻辑;监督期的能力(重启预算、日志轮转、通知)换班即生效。
///
/// 为什么不自己下载产物:发布站方案已弃用,产物只经 GitHub Release 与 mooncakes 分发。
/// 两条下载链路并存必然漂移,校验、清理、回滚都得维护两份。

///|
/// registry 的模块元数据,只取其中的 version 字段。
const REGISTRY_URL : String = "https://mooncakes.io/api/v0/modules/chensuiyi/bm2"

///|
/// registry 只是一个小 JSON,15 秒足够;卡住就按失败处理,不拖住 CLI。
const REGISTRY_TIMEOUT_MS : Int32 = 15000

///|
/// execvpe 找不到可执行文件时的退出码,用它区分「没装 moon」与其他失败。
const EXIT_COMMAND_NOT_FOUND : Int32 = 127

///|
/// HTTP GET 取文本。
pub async fn fetch_text(url : String) -> String {
  let (_response, body) = @http.get(url)
  @utf8.decode(body.binary())
}

///|
/// 从 registry 响应里取最新版本号。只认顶层 version 字段:
/// 其他字段的用途与本流程无关,多解析一处就多一处会随上游变更而失效的地方。
pub fn parse_registry_version(text : String) -> String? {
  let parsed = try @json.parse(text) catch {
    _ => return None
  } noraise {
    json => json
  }
  match parsed {
    Json::Object(fields) =>
      match fields.get("version") {
        Some(Json::String(version)) if !version.is_empty() => Some(version)
        _ => None
      }
    _ => None
  }
}

///|
/// 执行一个外部程序(NUL 分隔参数),输出直连终端。
/// 返回退出码;-1 表示起不来或被信号杀掉。
/// 不设超时:装多久、拉多少依赖由 moon 自己决定,卡住由用户 Ctrl+C 中断。
fn run_program(program : String, args_blob : String) -> Int32 {
  let pid = try
    @proc.spawn({
      bun_path: program,
      script: args_blob,
      cwd: "/",
      out_log: "",
      err_log: "",
      env_blob: @proc.base_env_blob(),
    })
  catch {
    _ => return -1
  } noraise {
    pid => pid
  }
  let exited = try @proc.wait_child(pid) catch {
    _ => return -1
  } noraise {
    event => event
  }
  match exited {
    Some((_, @proc.Exited(code))) => code
    Some((_, @proc.Signaled(_))) => -1
    None => -1
  }
}

///|
/// 装到 moon 的默认目录(~/.moon/bin)。不传 --bin:moon 的安装脚本已经把这个目录
/// 写进 PATH,按默认来才不会出现「装在 A、运行的是 B」。
/// `chensuiyi/bm2/...` 一次装齐两个 main 包,同批替换才不会 CLI 新、守护进程旧。
fn moon_install() -> Int32 {
  let args = "install" + "\u{0}" + "chensuiyi/bm2/..."
  run_program("moon", args)
}

///|
/// Upgrade through the moon toolchain, then hand over to the new daemon.
async fn cmd_upgrade(state_dir : String, lang : @i18n.Lang) -> Int32 {
  // 同一时刻只允许一个升级:两个并发会把同一批文件换来换去。
  @utils.discard(() => @fsx.mkdir_p(state_dir, mode=0o700))
  let _lock = try @fsx.lock_exclusive(state_dir + "/upgrade.lock") catch {
    _ => {
      @proc.eprintln(@i18n.upgrade_running(lang))
      return 1
    }
  } noraise {
    fd => fd
  }
  let url = REGISTRY_URL + "?t=" + @utils.now_ms().to_string()
  let fetched = try {
    let attempt = async fn() { fetch_text(url) }
    @async.with_timeout_opt(REGISTRY_TIMEOUT_MS, attempt)
  } catch {
    _ => None
  } noraise {
    text => text
  }
  let text = match fetched {
    Some(text) => text
    None => {
      @proc.eprintln(@i18n.upgrade_registry_unreachable(lang))
      return 1
    }
  }
  let latest = match parse_registry_version(text) {
    Some(version) => version
    None => {
      @proc.eprintln(@i18n.upgrade_bad_registry(lang))
      return 1
    }
  }
  if @utils.compare(@utils.parse(latest), @utils.parse(VERSION)) <= 0 {
    println(@i18n.update_up_to_date(lang, VERSION))
    return 0
  }
  println(@i18n.update_available(lang, latest, VERSION))
  // 装到 moon 的默认目录。手工把二进制放在别处的情况由文档约束:
  // 从 GitHub Release 下载也要放进 ~/.moon/bin,否则升级装到 A、运行的是 B。
  let code = moon_install()
  if code == EXIT_COMMAND_NOT_FOUND {
    @proc.eprintln(@i18n.upgrade_no_moon(lang))
    return 1
  }
  if code != 0 {
    @proc.eprintln(@i18n.upgrade_install_failed(lang, code))
    return 1
  }
  // 装完才换班:失败了旧版本照常运行,不会出现半套新版本。
  apply_update(state_dir, lang)
}
