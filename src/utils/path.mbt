///|
/// 拼接两段路径。斜杠的归一化交给 core 的 `Path`：多一个少一个、末尾带不带
/// 斜杠、`.` 与 `..` 都由它处理，调用点不再自己数分隔符。
///
/// 第二段总是接在后面，即便它以 `/` 开头（实测 `Path` 的 `/` 是无条件拼接，
/// 不采用 POSIX「绝对路径覆盖」的语义），所以把用户输入当文件名拼进来也不会
/// 意外跳出父目录。
pub fn join_path(head : String, tail : String) -> String {
  (@path.Path::Path(head) / @path.Path::Path(tail)).to_string()
}
