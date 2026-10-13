///|
pub(all) suberror FileError {
  Failed(op~ : String, errno~ : Int32)
}

///|
pub impl Show for FileError with fn output(self, logger) {
  match self {
    Failed(op~, errno~) => {
      logger.write_string(op)
      logger.write_string(" failed: errno ")
      logger.write_string(errno.to_string())
    }
  }
}

///|
pub extend FileError with Show::{to_string, output}

///|
fn cstr(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
#borrow(path)
extern "C" fn c_mkdir_p(path : Bytes, mode : Int32) -> Int32 = "fsx_mkdir_p"

///|
#borrow(path, data)
extern "C" fn c_write_atomic(path : Bytes, data : Bytes) -> Int32 = "fsx_write_atomic"

///|
#borrow(path, data)
extern "C" fn c_write_atomic_fast(path : Bytes, data : Bytes) -> Int32 = "fsx_write_atomic_fast"

///|
#borrow(path, data)
extern "C" fn c_append_file(path : Bytes, data : Bytes) -> Int32 = "fsx_append_file"

///|
#borrow(path)
extern "C" fn c_unlink(path : Bytes) -> Int32 = "fsx_unlink"

///|
#borrow(path)
extern "C" fn c_chmod(path : Bytes, mode : Int32) -> Int32 = "fsx_chmod"

///|
#borrow(path)
extern "C" fn c_file_size(path : Bytes) -> Int64 = "fsx_file_size"

///|
#borrow(path)
extern "C" fn c_rotate(path : Bytes) -> Int32 = "fsx_rotate"

///|
#borrow(path)
extern "C" fn c_copytruncate(path : Bytes) -> Int32 = "fsx_copytruncate"

///|
#borrow(path)
extern "C" fn c_lock_exclusive(path : Bytes) -> Int32 = "fsx_lock_exclusive"

///|
#borrow(path, buf)
extern "C" fn c_read_small(path : Bytes, buf : Bytes, cap : Int32) -> Int32 = "fsx_read_small"

///|
#borrow(path)
extern "C" fn c_dir_owner(path : Bytes) -> Int32 = "fsx_dir_owner"
