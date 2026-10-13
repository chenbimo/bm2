///|
/// 自升级的下载侧:读取发布站的更新清单(本项目发布产物的格式),
/// 按本机平台取产物,下载并校验。

///|
/// How long the manifest may take: it is a small JSON document on a static host.
const UPDATE_MANIFEST_TIMEOUT_MS : Int32 = 30000

///|
/// How long one artifact may take. Binaries are a few MB, so this is generous on
/// purpose — a slow link must still finish — but a stalled connection has to fail
/// the update instead of hanging the CLI.
const UPDATE_DOWNLOAD_TIMEOUT_MS : Int32 = 300000

///|
/// 发布站地址(可用环境变量覆盖,便于内网镜像与测试)。
pub fn update_base() -> String {
  match @env.get_env_var("BM2_UPDATE_BASE") {
    Some(url) if !url.is_empty() => url
    _ => "https://static2.yicode.tech"
  }
}

///|
/// 本机平台架构标识(与清单 artifacts[].target 对齐)。
/// 读自身 ELF 头的 e_machine,不需要子进程:0xB7 是 aarch64,其余按 x86-64 处理。
pub fn self_target() -> String {
  let exe = try @proc.self_exe() catch {
    _ => return "linux-x64"
  } noraise {
    path => path
  }
  let head = try @fsx.read_small(exe, cap=64) catch {
    _ => return "linux-x64"
  } noraise {
    data => data
  }
  if head.length() < 20 {
    return "linux-x64"
  }
  let machine = head[18].to_int() + head[19].to_int() * 256
  if machine == 0xb7 {
    "linux-arm64"
  } else {
    "linux-x64"
  }
}

///|
/// 更新清单里的一个产物。
pub struct UpdateArtifact {
  name : String
  target : String
  url : String
  sha256 : String
} derive(Debug, Eq)

///|
/// 解析发布清单:版本号与产物列表。字段手工提取,因为清单键是驼峰
/// (`fileSize`),与 MoonBit 的 snake_case 字段命名不兼容。
pub fn parse_manifest(text : String) -> (String, Array[UpdateArtifact])? {
  let parsed = try @json.parse(text) catch {
    _ => return None
  } noraise {
    json => json
  }
  let fields = match parsed {
    Json::Object(fields) => fields
    _ => return None
  }
  let version = json_string(fields, "version")
  if version.is_empty() {
    return None
  }
  let items = match fields.get("artifacts") {
    Some(Json::Array(items)) => items
    _ => return None
  }
  let artifacts : Array[UpdateArtifact] = []
  for item in items {
    match item {
      Json::Object(entry) => {
        let name = json_string(entry, "name")
        let url = json_string(entry, "url")
        let digest = json_string(entry, "sha256")
        if name.is_empty() || url.is_empty() || digest.is_empty() {
          continue
        }
        artifacts.push({
          name,
          target: json_string(entry, "target"),
          url,
          sha256: digest,
        })
      }
      _ => continue
    }
  }
  Some((version, artifacts))
}

///|
fn json_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
/// 取本机平台下的全部必需产物:先精确匹配 target,再回退 any。
/// 任一必需产物缺失即返回 None(缺一不可,避免半更新)。
pub fn pick_artifacts(
  artifacts : Array[UpdateArtifact],
  target : String,
  names : Array[String],
) -> Array[UpdateArtifact]? {
  let picked : Array[UpdateArtifact] = []
  for name in names {
    let mut exact : UpdateArtifact? = None
    let mut fallback : UpdateArtifact? = None
    for item in artifacts {
      if item.name != name {
        continue
      }
      if item.target == target {
        exact = Some(item)
        break
      }
      if item.target == "any" {
        fallback = Some(item)
      }
    }
    match exact {
      Some(item) => picked.push(item)
      None =>
        match fallback {
          Some(item) => picked.push(item)
          None => return None
        }
    }
  }
  Some(picked)
}

///|
/// 拉取一段文本(更新清单)。
pub async fn fetch_text(url : String) -> String {
  let (_response, body) = @http.get(url)
  @utf8.decode(body.binary())
}

///|
/// 下载到本地文件。产物只有几 MB,整块读进内存再落盘,无需流式句柄。
pub async fn download_to(url : String, path : String) -> Unit {
  let (_response, body) = @http.get(url)
  @fs.write_bytes_to_file(path, body.binary())
}

///|
/// 文件的 SHA256,小写十六进制。
pub fn sha256_hex(path : String) -> String raise {
  @crypto.bytes_to_hex_string(@crypto.sha256(@fs.read_file_to_bytes(path)))
}

///|
/// 执行一个外部程序(NUL 分隔参数),输出直连终端,退出码 0 视为成功。
fn run_program(program : String, args_blob : String) -> Bool {
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
    _ => return false
  } noraise {
    spawned => spawned
  }
  let reaped = try @proc.wait_child(pid) catch {
    _ => None
  } noraise {
    result => result
  }
  match reaped {
    Some((_, @proc.ChildExit::Exited(0))) => true
    _ => false
  }
}

///|
/// 下载并安装一批产物。全部下载与校验通过后才动现有二进制;替换失败用
/// 备份还原。返回错误说明,None 表示成功。
pub async fn install_artifacts(
  picked : Array[UpdateArtifact],
  dir : String,
) -> String? {
  let staged : Array[UpdateArtifact] = []
  for item in picked {
    let temp = dir + "/." + item.name + ".new"
    if !download_ok(item.url, temp) {
      remove_file(temp)
      return Some("cannot download " + item.url)
    }
    let actual = try sha256_hex(temp) catch {
      _ => ""
    } noraise {
      digest => digest
    }
    if actual != item.sha256 {
      remove_file(temp)
      return Some("checksum mismatch for " + item.name + "; update aborted")
    }
    if !make_executable(temp) {
      remove_file(temp)
      return Some("cannot mark " + item.name + " executable")
    }
    staged.push(item)
  }
  // 替换:先备份旧文件再改名;同文件系统内的 mv 是原子的。
  let backed : Array[String] = []
  for item in staged {
    let destination = dir + "/" + item.name
    let saved = destination + ".bak"
    let had_old = @fs.path_exists(destination)
    if had_old && !move_file(destination, saved) {
      restore(dir, backed)
      return Some("cannot replace " + item.name)
    }
    if !move_file(dir + "/." + item.name + ".new", destination) {
      restore(dir, backed)
      return Some("cannot replace " + item.name)
    }
    if had_old {
      backed.push(item.name)
    }
  }
  for name in backed {
    remove_file(dir + "/" + name + ".bak")
  }
  None
}

///|
/// Download one artifact inside a bounded wait.
async fn download_ok(url : String, path : String) -> Bool {
  let failed = try {
    let attempt = async fn() { download_to(url, path) }
    match @async.with_timeout_opt(UPDATE_DOWNLOAD_TIMEOUT_MS, attempt) {
      Some(_) => false
      None => true
    }
  } catch {
    _ => true
  } noraise {
    flag => flag
  }
  !failed
}

///|
fn make_executable(path : String) -> Bool {
  let failed = try {
    @fsx.chmod(path, 0o755)
    false
  } catch {
    _ => true
  } noraise {
    flag => flag
  }
  !failed
}

///|
fn move_file(source : String, destination : String) -> Bool {
  run_program("mv", source + "\u{0}-f\u{0}" + destination + "\u{0}")
}

///|
fn remove_file(path : String) -> Unit {
  try @fsx.unlink(path) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// 回滚已替换的文件:删掉新文件,把备份改回正式名。
fn restore(dir : String, backed : Array[String]) -> Unit {
  for name in backed {
    let destination = dir + "/" + name
    remove_file(destination)
    ignore(move_file(destination + ".bak", destination))
  }
}

///|
/// Upgrade bm2 from the release station: fetch the manifest, compare the
/// published version with the running one, download this platform's binaries,
/// verify their SHA256, swap them in place, then swap the daemon so the new
/// binary takes over without touching the running apps.
async fn cmd_upgrade(state_dir : String) -> Int32 {
  // One upgrade at a time: two of them would stage and swap the same files. The
  // lock is released when this process exits, so a crashed upgrade never blocks
  // the next one.
  @utils.discard(() => @fsx.mkdir_p(state_dir, mode=0o700))
  let _lock = try @fsx.lock_exclusive(state_dir + "/upgrade.lock") catch {
    _ => {
      @proc.eprintln("bm2: another upgrade is already running")
      return 1
    }
  } noraise {
    fd => fd
  }
  let base = update_base()
  let manifest_url = base +
    "/products/bm2/latest.json?t=" +
    @utils.now_ms().to_string()
  let fetched = try {
    let attempt = async fn() { fetch_text(manifest_url) }
    @async.with_timeout_opt(UPDATE_MANIFEST_TIMEOUT_MS, attempt)
  } catch {
    _ => None
  } noraise {
    text => text
  }
  let text = match fetched {
    Some(text) => text
    None => {
      @proc.eprintln("bm2: cannot reach the release station " + base)
      return 1
    }
  }
  let (version, artifacts) = match parse_manifest(text) {
    Some(parsed) => parsed
    None => {
      @proc.eprintln("bm2: cannot read the release manifest")
      return 1
    }
  }
  if @utils.compare(@utils.parse(version), @utils.parse(VERSION)) <= 0 {
    println("bm2 is up to date (" + VERSION + ")")
    return 0
  }
  println("new version " + version + " available (current " + VERSION + ")")
  let target = self_target()
  // bm2 与 bm2d 必须同批取到,缺一不可,否则会出现半更新。
  let picked = match pick_artifacts(artifacts, target, ["bm2", "bm2d"]) {
    Some(items) => items
    None => {
      @proc.eprintln("bm2: no release for " + target + " yet")
      return 1
    }
  }
  match install_artifacts(picked, self_dir()) {
    Some(reason) => {
      @proc.eprintln("bm2: " + reason)
      return 1
    }
    None => ()
  }
  // Apply immediately when a daemon is running; a failed swap still
  // leaves the update installed, so only the message differs.
  apply_update(state_dir)
}
