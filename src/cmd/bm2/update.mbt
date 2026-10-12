///|
/// 自升级的下载侧:读取发布站的更新清单,按本机平台取产物,下载并校验。
/// 清单与目录布局的条文见 yicode-tech 仓库 `specs/update-spec.md`。

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
  let exe = try @util.self_exe() catch {
    _ => return "linux-x64"
  } noraise {
    path => path
  }
  let head = try @util.read_small(exe, cap=64) catch {
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
  let digest = @crypto.sha256(@fs.read_file_to_bytes(path))
  let out = StringBuilder()
  for byte in digest {
    out.write_string(hex_pair(byte.to_int()))
  }
  out.to_string()
}

///|
let hex_digits : Array[String] = [
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
]

///|
fn hex_pair(value : Int32) -> String {
  hex_digits[(value >> 4) & 0xf] + hex_digits[value & 0xf]
}

///|
/// 执行一个外部程序(NUL 分隔参数),输出直连终端,退出码 0 视为成功。
fn run_program(program : String, args_blob : String) -> Bool {
  let pid = try
    @util.spawn({
      bun_path: program,
      script: args_blob,
      cwd: "/",
      out_log: "",
      err_log: "",
      env_blob: @util.base_env_blob(),
    })
  catch {
    _ => return false
  } noraise {
    spawned => spawned
  }
  let reaped = try @util.wait_child(pid) catch {
    _ => None
  } noraise {
    result => result
  }
  match reaped {
    Some((_, @util.ChildExit::Exited(0))) => true
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
async fn download_ok(url : String, path : String) -> Bool {
  let failed = try {
    download_to(url, path)
    false
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
    @util.chmod(path, 0o755)
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
  try @util.unlink(path) catch {
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
