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

/* Write data to "<path>.tmp", fsync, then atomically rename over path. */
MOONBIT_FFI_EXPORT
int32_t fsx_write_atomic(moonbit_bytes_t path, moonbit_bytes_t data) {
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
  sync_parent_dir((char *)path);
  return 0;
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

/* Shift the rotation chain (path.N -> path.N+1), then rename path to
 * path.1. Drops path.10, keeping ten archived generations. Used for logs
 * written by the daemon itself, where no fd survives the rename. */
MOONBIT_FFI_EXPORT
int32_t fsx_rotate(moonbit_bytes_t path) {
  char buf[4096];
  size_t len = strlen((char *)path);
  if (len + 5 >= sizeof(buf)) return -ENAMETOOLONG;
  snprintf(buf, sizeof(buf), "%s.10", (char *)path);
  unlink(buf);
  for (int i = 9; i >= 1; i--) {
    snprintf(buf, sizeof(buf), "%s.%d", (char *)path, i);
    char next[4096];
    snprintf(next, sizeof(next), "%s.%d", (char *)path, i + 1);
    if (rename(buf, next) != 0 && errno != ENOENT) {
      /* a missing generation is fine; anything else leaves a gap */
    }
  }
  snprintf(buf, sizeof(buf), "%s.1", (char *)path);
  if (rename((char *)path, buf) != 0 && errno != ENOENT) return -errno;
  return 0;
}

/* Copy path into path.1 (shifting the chain), then truncate path to zero.
 * App processes keep writing to the old inode after the copy, so their
 * output continues into the truncated file; a few bytes written during the
 * copy are lost, which is the accepted trade-off for fd-held logs. */
MOONBIT_FFI_EXPORT
int32_t fsx_copytruncate(moonbit_bytes_t path) {
  char buf[4096];
  size_t len = strlen((char *)path);
  if (len + 5 >= sizeof(buf)) return -ENAMETOOLONG;
  snprintf(buf, sizeof(buf), "%s.10", (char *)path);
  unlink(buf);
  for (int i = 9; i >= 1; i--) {
    snprintf(buf, sizeof(buf), "%s.%d", (char *)path, i);
    char next[4096];
    snprintf(next, sizeof(next), "%s.%d", (char *)path, i + 1);
    if (rename(buf, next) != 0 && errno != ENOENT) {
      /* a missing generation is fine; anything else leaves a gap */
    }
  }
  /* O_RDWR so the in-place ftruncate below can shrink the file. */
  int src = open((char *)path, O_RDWR);
  if (src < 0) return errno == ENOENT ? 0 : -errno;
  snprintf(buf, sizeof(buf), "%s.1", (char *)path);
  int dst = open(buf, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (dst < 0) {
    int err = errno;
    close(src);
    return -err;
  }
  uint8_t chunk[65536];
  int rc = 0;
  for (;;) {
    ssize_t n = read(src, chunk, sizeof(chunk));
    if (n < 0) {
      if (errno == EINTR) continue;
      rc = -errno;
      break;
    }
    if (n == 0) break;
    if (write_all(dst, chunk, (size_t)n) != 0) {
      rc = -errno;
      break;
    }
  }
  if (rc == 0 && ftruncate(src, 0) != 0) rc = -errno;
  close(src);
  close(dst);
  return rc;
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
