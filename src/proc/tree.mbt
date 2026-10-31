///|
/// Direct children of one process, read from `/proc/<pid>/task/<tid>/children`.
///
/// The kernel keeps that list per thread, so a multi-threaded parent repeats
/// its children once per thread. The result is deduplicated because callers sum
/// or signal, and doing either twice on the same pid is wrong.
///
/// `CONFIG_PROC_CHILDREN` is on in every mainstream distribution, but when the
/// file is missing the answer is an empty list rather than an error: the caller
/// then treats the process as a leaf, which is the pre-tree behaviour.
pub fn children_of(pid : Int32) -> Array[Int32] {
  let threads = match read_proc_dir("/proc/\{pid}/task") {
    None => return []
    Some(entries) => entries
  }
  let seen : Array[Int32] = []
  for tid in threads {
    let text = match read_proc_text("/proc/\{pid}/task/\{tid}/children") {
      None => continue
      Some(body) => body
    }
    for field in @utils.split(text.trim().to_owned(), " ") {
      if field.is_empty() {
        continue
      }
      let child = match u64_of(field) {
        None => continue
        Some(value) => value.to_int()
      }
      if child > 0 && !seen.contains(child) {
        seen.push(child)
      }
    }
  }
  seen
}

///|
/// `pid` and everything below it, breadth first. `limit` bounds the walk so a
/// fork bomb cannot make the daemon allocate without end; when the budget runs
/// out the tree is returned truncated instead of growing forever.
pub fn process_tree(pid : Int32, limit : Int32) -> Array[Int32] {
  let tree : Array[Int32] = [pid]
  let mut index = 0
  while index < tree.length() && tree.length() < limit {
    let current = tree[index]
    index += 1
    for child in children_of(current) {
      if tree.length() >= limit {
        break
      }
      if !tree.contains(child) {
        tree.push(child)
      }
    }
  }
  tree
}

///|
/// VmRSS summed over the whole process tree under `pid`, in kB. `None` when the
/// root itself is gone.
///
/// Summing matters because a managed app is rarely one process: Bun and Node
/// both spawn workers, and a limit that only watched the leader would let the
/// tree grow past it unnoticed. `limit` is the project's own bound on how many
/// processes that sum may cover.
pub fn tree_rss_kb(pid : Int32, limit : Int32) -> Int32? {
  let mut total = match read_rss_kb(pid) {
    None => return None
    Some(kb) => kb
  }
  for node in process_tree(pid, limit) {
    if node == pid {
      continue
    }
    match read_rss_kb(node) {
      None => ()
      Some(kb) => total += kb
    }
  }
  Some(total)
}
