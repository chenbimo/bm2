#define _GNU_SOURCE

#include <moonbit.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* All paths/strings passed from MoonBit are Bytes with a trailing NUL. */

/*
 * Deadlines for file reads/writes (log appends, atomic writes, truncation).
 * A full disk or a stalled target must not hang the daemon, so every
 * write step is bounded by poll.
 */
#define FSX_TIMEOUT_MS 5000

static int poll_out(int fd, int timeout_ms) {
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLOUT;
  pfd.revents = 0;
  int rc;
  do {
    rc = poll(&pfd, 1, timeout_ms);
  } while (rc < 0 && errno == EINTR);
  return rc;
}

static int write_all(int fd, const uint8_t *data, size_t len) {
  size_t off = 0;
  while (off < len) {
    int rc = poll_out(fd, FSX_TIMEOUT_MS);
    if (rc < 0) return -errno;
    if (rc == 0) return -ETIMEDOUT;
    ssize_t n = write(fd, data + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -errno;
    }
    off += (size_t)n;
  }
  return 0;
}

/* fsync the directory holding path, so the rename itself (not just the file
 * contents) survives a power loss. Best effort: the data is already in
 * place by then, and a filesystem that cannot fsync a directory must not
 * turn a completed write into a reported failure. */
static void sync_parent_dir(const char *path) {
  char dir[4096];
  size_t len = strlen(path);
  if (len >= sizeof(dir)) return;
  memcpy(dir, path, len + 1);
  char *slash = strrchr(dir, '/');
  if (slash == NULL) {
    dir[0] = '.';
    dir[1] = 0;
  } else if (slash == dir) {
    slash[1] = 0;
  } else {
    *slash = 0;
  }
  int fd = open(dir, O_RDONLY | O_DIRECTORY);
  if (fd < 0) return;
  fsync(fd);
  close(fd);
}

MOONBIT_FFI_EXPORT
int32_t fsx_mkdir_p(moonbit_bytes_t path, int32_t mode) {
  char buf[4096];
  size_t len = strlen((char *)path);
  if (len == 0 || len >= sizeof(buf)) return -ENAMETOOLONG;
  memcpy(buf, path, len + 1);
  for (char *p = buf + 1; *p != 0; p++) {
    if (*p == '/') {
      *p = 0;
      if (mkdir(buf, (mode_t)mode) != 0 && errno != EEXIST) return -errno;
      *p = '/';
    }
  }
  if (mkdir(buf, (mode_t)mode) != 0 && errno != EEXIST) return -errno;
  return 0;
}

/* Write data to "<path>.tmp", fsync, then atomically rename over path.
 * `sync_dir` additionally fsyncs the directory, which is what makes the rename
 * itself survive a power loss. */
static int32_t write_atomic_impl(moonbit_bytes_t path, moonbit_bytes_t data,
                                 int sync_dir) {
  char tmp[4096];
  size_t len = strlen((char *)path);
  if (len + 5 >= sizeof(tmp)) return -ENAMETOOLONG;
  memcpy(tmp, path, len);
  memcpy(tmp + len, ".tmp", 5);
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return -errno;
  int rc = write_all(fd, data, (size_t)Moonbit_array_length(data));
  if (rc == 0 && fsync(fd) != 0) rc = -errno;
  if (close(fd) != 0 && rc == 0) rc = -errno;
  if (rc != 0) {
    unlink(tmp);
    return rc;
  }
  if (rename(tmp, (char *)path) != 0) {
    int err = errno;
    unlink(tmp);
    return -err;
  }
  if (sync_dir) sync_parent_dir((char *)path);
  return 0;
}

/* The durable form: contents and directory entry. */
MOONBIT_FFI_EXPORT
int32_t fsx_write_atomic(moonbit_bytes_t path, moonbit_bytes_t data) {
  return write_atomic_impl(path, data, 1);
}

/* The same write without the directory fsync: for files rewritten on every
 * spawn that are reconstructible from the running state (per-instance
 * supervision state), the directory entry does not need to survive a power loss
 * on its own — and this saves one fsync per instance per start. */
MOONBIT_FFI_EXPORT
int32_t fsx_write_atomic_fast(moonbit_bytes_t path, moonbit_bytes_t data) {
  return write_atomic_impl(path, data, 0);
}

MOONBIT_FFI_EXPORT
int32_t fsx_append_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  int fd = open((char *)path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd < 0) return -errno;
  int rc = write_all(fd, data, (size_t)Moonbit_array_length(data));
  if (close(fd) != 0 && rc == 0) rc = -errno;
  return rc;
}

MOONBIT_FFI_EXPORT
int32_t fsx_unlink(moonbit_bytes_t path) {
  return unlink((char *)path) == 0 ? 0 : -errno;
}

/* Tighten the mode of an existing path; mkdir only applies a mode to newly
 * created directories, so an older or hand-made state dir keeps whatever
 * permissions it has unless it is chmodded explicitly. */
MOONBIT_FFI_EXPORT
int32_t fsx_chmod(moonbit_bytes_t path, int32_t mode) {
  return chmod((char *)path, (mode_t)mode) == 0 ? 0 : -errno;
}

/* File size in bytes, or -errno. Used to decide when a log rotates. */
MOONBIT_FFI_EXPORT
int64_t fsx_file_size(moonbit_bytes_t path) {
  struct stat st;
  if (stat((char *)path, &st) != 0) return -errno;
  return (int64_t)st.st_size;
}

/* Take a non-blocking exclusive flock on path; caller keeps the fd. The
 * fd is CLOEXEC so spawned apps never inherit it: otherwise an app would
 * keep holding the lock after the daemon dies (e.g. SIGKILL), blocking
 * the next daemon from starting. */
MOONBIT_FFI_EXPORT
int32_t fsx_lock_exclusive(moonbit_bytes_t path) {
  int fd = open((char *)path, O_RDWR | O_CREAT, 0600);
  if (fd < 0) return -errno;
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  return fd;
}

/* Read a small file into a buffer (works on /proc virtual files, unlike
 * ftell-based readers); loops until EOF so long entries are not truncated.
 * Returns byte count or -errno. */
MOONBIT_FFI_EXPORT
int32_t fsx_read_small(moonbit_bytes_t path, moonbit_bytes_t buf,
                       int32_t cap) {
  int fd = open((char *)path, O_RDONLY);
  if (fd < 0) return -errno;
  size_t off = 0;
  while (off < (size_t)cap) {
    ssize_t n = read(fd, (char *)buf + off, (size_t)cap - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      int err = errno;
      close(fd);
      return -err;
    }
    if (n == 0) break;
    off += (size_t)n;
  }
  close(fd);
  return (int32_t)off;
}

/* Owner uid of a directory, -ENOTDIR when the path is not one, -errno on
 * failure. The state dir holds the control-plane token, so the daemon verifies
 * this before trusting it: the HOME-less fallback (/tmp/bm2-<uid>) must not be
 * a directory that some other local user created first. */
MOONBIT_FFI_EXPORT
int32_t fsx_dir_owner(moonbit_bytes_t path) {
  struct stat st;
  if (stat((char *)path, &st) != 0) return -errno;
  if (!S_ISDIR(st.st_mode)) return -ENOTDIR;
  return (int32_t)st.st_uid;
}

/* Resolve a path to its canonical form (symlinks, "." and ".." folded) into the
 * caller's buffer. Returns the length written, or -errno.
 *
 * Project identity is a name plus the config file that registered it, and the
 * same file reached through a symlink, a relative path or ".." has to compare
 * equal — so both sides of that comparison are canonicalized through here. */
MOONBIT_FFI_EXPORT
int32_t fsx_realpath(moonbit_bytes_t path, moonbit_bytes_t buf, int32_t cap) {
  char resolved[4096];
  if (realpath((char *)path, resolved) == NULL) return -errno;
  size_t len = strlen(resolved);
  if (len > (size_t)cap) return -ENAMETOOLONG;
  memcpy(buf, resolved, len);
  return (int32_t)len;
}
