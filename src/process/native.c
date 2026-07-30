#define _GNU_SOURCE

#include <moonbit.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* All paths/strings passed from MoonBit are Bytes with a trailing NUL. */

static int redirect_fd(const char *path, int target_fd) {
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd < 0) return -1;
  if (dup2(fd, target_fd) < 0) {
    close(fd);
    return -1;
  }
  close(fd);
  return 0;
}

/*
 * env_blob is a sequence of NUL-terminated "KEY=VALUE" entries,
 * with an extra NUL marking the end (double NUL terminator).
 * Returns the child pid, or -errno on failure.
 */
MOONBIT_FFI_EXPORT
int32_t bm2_spawn(moonbit_bytes_t bun_path, moonbit_bytes_t script,
                  moonbit_bytes_t cwd, moonbit_bytes_t out_path,
                  moonbit_bytes_t err_path, moonbit_bytes_t env_blob) {
  int blob_len = Moonbit_array_length(env_blob);
  int nul_count = 0;
  for (int i = 0; i < blob_len; i++) {
    if (env_blob[i] == 0) nul_count++;
  }
  char **envp = malloc(sizeof(char *) * (size_t)(nul_count + 1));
  if (envp == NULL) return -ENOMEM;
  int idx = 0;
  char *p = (char *)env_blob;
  char *end = p + blob_len;
  while (p < end && *p != 0) {
    envp[idx++] = p;
    p += strlen(p) + 1;
  }
  envp[idx] = NULL;

  pid_t pid = fork();
  if (pid < 0) {
    int err = errno;
    free(envp);
    return -err;
  }
  if (pid == 0) {
    /* Child: fresh session so the instance gets its own process group. */
    setsid();
    if (chdir((char *)cwd) != 0) _exit(126);
    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) {
      dup2(devnull, STDIN_FILENO);
      close(devnull);
    }
    if (redirect_fd((char *)out_path, STDOUT_FILENO) != 0) _exit(126);
    if (redirect_fd((char *)err_path, STDERR_FILENO) != 0) _exit(126);
    char *argv[] = {(char *)bun_path, (char *)script, NULL};
    /* execvpe: resolve a bare "bun" via PATH from envp (_GNU_SOURCE). */
    execvpe((char *)bun_path, argv, envp);
    _exit(127);
  }
  free(envp);
  return (int32_t)pid;
}

/*
 * out must hold at least 12 bytes; receives three little-endian int32:
 * reaped pid (>0), raw wait status, errno (only when reaped pid < 0).
 */
MOONBIT_FFI_EXPORT
int32_t bm2_waitpid(int32_t pid, int32_t nohang, moonbit_bytes_t out) {
  int status = 0;
  errno = 0;
  pid_t r = waitpid((pid_t)pid, &status, nohang ? WNOHANG : 0);
  int32_t vals[3];
  vals[0] = (int32_t)r;
  vals[1] = (r > 0) ? (int32_t)status : 0;
  vals[2] = (r < 0) ? (int32_t)errno : 0;
  memcpy(out, vals, sizeof(vals));
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t bm2_kill_pg(int32_t pgid, int32_t sig) {
  return kill(-(pid_t)pgid, sig) == 0 ? 0 : -errno;
}

MOONBIT_FFI_EXPORT
int32_t bm2_kill0(int32_t pid) {
  return kill((pid_t)pid, 0) == 0 ? 0 : -errno;
}

MOONBIT_FFI_EXPORT
int32_t bm2_getpid(void) {
  return (int32_t)getpid();
}

/* VmRSS in kB from /proc/<pid>/status, or -1 when unavailable. */
MOONBIT_FFI_EXPORT
int32_t bm2_read_rss_kb(int32_t pid) {
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/status", pid);
  FILE *f = fopen(path, "r");
  if (f == NULL) return -1;
  char line[256];
  long rss = -1;
  while (fgets(line, sizeof(line), f) != NULL) {
    if (strncmp(line, "VmRSS:", 6) == 0) {
      rss = strtol(line + 6, NULL, 10);
      break;
    }
  }
  fclose(f);
  return (int32_t)rss;
}

MOONBIT_FFI_EXPORT
void bm2_sleep_ms(int32_t ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
}

MOONBIT_FFI_EXPORT
int32_t bm2_mkdir_p(moonbit_bytes_t path, int32_t mode) {
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

static int write_all(int fd, const uint8_t *data, size_t len) {
  size_t off = 0;
  while (off < len) {
    ssize_t n = write(fd, data + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -errno;
    }
    off += (size_t)n;
  }
  return 0;
}

/* Write data to "<path>.tmp", fsync, then atomically rename over path. */
MOONBIT_FFI_EXPORT
int32_t bm2_write_atomic(moonbit_bytes_t path, moonbit_bytes_t data) {
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
  if (rename(tmp, (char *)path) != 0) return -errno;
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t bm2_append_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  int fd = open((char *)path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd < 0) return -errno;
  int rc = write_all(fd, data, (size_t)Moonbit_array_length(data));
  if (close(fd) != 0 && rc == 0) rc = -errno;
  return rc;
}

MOONBIT_FFI_EXPORT
int32_t bm2_unlink(moonbit_bytes_t path) {
  return unlink((char *)path) == 0 ? 0 : -errno;
}

/* ---------------- Unix domain socket ---------------- */

static int make_addr(moonbit_bytes_t path, struct sockaddr_un *addr) {
  size_t len = strlen((char *)path);
  if (len == 0 || len >= sizeof(addr->sun_path)) return -1;
  memset(addr, 0, sizeof(*addr));
  addr->sun_family = AF_UNIX;
  memcpy(addr->sun_path, path, len + 1);
  return 0;
}

/* A peer that vanishes mid-write must not kill the process: ignore
 * SIGPIPE so socket writes fail with EPIPE instead. Applies to both the
 * daemon (listen) and the CLI (connect). */
static void ignore_sigpipe(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = SIG_IGN;
  sigaction(SIGPIPE, &sa, NULL);
}

/* Listen on a fresh AF_UNIX socket at path (stale path unlinked, 0600). */
MOONBIT_FFI_EXPORT
int32_t bm2_socket_listen(moonbit_bytes_t path) {
  ignore_sigpipe();
  struct sockaddr_un addr;
  if (make_addr(path, &addr) != 0) return -ENAMETOOLONG;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -errno;
  unlink((char *)path);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  chmod((char *)path, 0600);
  if (listen(fd, 16) != 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  return fd;
}

MOONBIT_FFI_EXPORT
int32_t bm2_socket_connect(moonbit_bytes_t path) {
  ignore_sigpipe();
  struct sockaddr_un addr;
  if (make_addr(path, &addr) != 0) return -ENAMETOOLONG;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -errno;
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    int err = errno;
    close(fd);
    return -err;
  }
  return fd;
}

/* 1 when readable, 0 on timeout, -errno on error. */
MOONBIT_FFI_EXPORT
int32_t bm2_poll_fd(int32_t fd, int32_t timeout_ms) {
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int rc;
  do {
    rc = poll(&pfd, 1, timeout_ms);
  } while (rc < 0 && errno == EINTR);
  if (rc < 0) return -errno;
  if (rc == 0) return 0;
  return 1;
}

MOONBIT_FFI_EXPORT
int32_t bm2_accept(int32_t listen_fd) {
  int fd = accept(listen_fd, NULL, NULL);
  return fd < 0 ? -errno : fd;
}

MOONBIT_FFI_EXPORT
int32_t bm2_close(int32_t fd) {
  return close(fd) == 0 ? 0 : -errno;
}

/* Length-prefixed messages: 4-byte big-endian length + JSON payload. */

static int read_exact(int fd, uint8_t *buf, size_t len) {
  size_t off = 0;
  while (off < len) {
    ssize_t n = read(fd, buf + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -errno;
    }
    if (n == 0) return -ECONNRESET;
    off += (size_t)n;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t bm2_send_msg(int32_t fd, moonbit_bytes_t data) {
  uint32_t len = (uint32_t)Moonbit_array_length(data);
  uint8_t header[4];
  header[0] = (uint8_t)(len >> 24);
  header[1] = (uint8_t)(len >> 16);
  header[2] = (uint8_t)(len >> 8);
  header[3] = (uint8_t)len;
  int rc = write_all(fd, header, 4);
  if (rc == 0) rc = write_all(fd, data, len);
  return rc;
}

/* Reads one message into buf; returns payload length, -errno, or
 * -EMSGSIZE when the payload exceeds cap. */
MOONBIT_FFI_EXPORT
int32_t bm2_recv_msg(int32_t fd, moonbit_bytes_t buf, int32_t cap) {
  uint8_t header[4];
  int rc = read_exact(fd, header, 4);
  if (rc != 0) return rc;
  uint32_t len = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) |
                 ((uint32_t)header[2] << 8) | (uint32_t)header[3];
  if (len > (uint32_t)cap) return -EMSGSIZE;
  rc = read_exact(fd, buf, len);
  if (rc != 0) return rc;
  return (int32_t)len;
}

/* uid of the connected peer, for same-user enforcement. */
MOONBIT_FFI_EXPORT
int32_t bm2_peer_uid(int32_t fd) {
  struct ucred {
    pid_t pid;
    uid_t uid;
    gid_t gid;
  } cred;
  socklen_t len = sizeof(cred);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
    return -errno;
  }
  return (int32_t)cred.uid;
}

MOONBIT_FFI_EXPORT
int32_t bm2_getuid(void) {
  return (int32_t)getuid();
}

/* ---------------- daemon helpers ---------------- */

MOONBIT_FFI_EXPORT
int32_t bm2_self_exe(moonbit_bytes_t buf, int32_t cap) {
  ssize_t n = readlink("/proc/self/exe", (char *)buf, (size_t)cap - 1);
  if (n < 0) return -errno;
  buf[n] = 0;
  return (int32_t)n;
}

/* Read a small file (works on /proc virtual files, unlike ftell-based
 * readers); returns byte count or -errno. */
MOONBIT_FFI_EXPORT
int32_t bm2_read_small(moonbit_bytes_t path, moonbit_bytes_t buf, int32_t cap) {
  int fd = open((char *)path, O_RDONLY);
  if (fd < 0) return -errno;
  ssize_t n = read(fd, buf, (size_t)cap);
  int err = errno;
  close(fd);
  return n < 0 ? -err : (int32_t)n;
}

static volatile sig_atomic_t g_term_flag = 0;

static void on_term(int sig) {
  (void)sig;
  g_term_flag = 1;
}

MOONBIT_FFI_EXPORT
void bm2_install_term_handler(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_term;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
}

MOONBIT_FFI_EXPORT
int32_t bm2_term_flag(void) {
  return g_term_flag;
}

MOONBIT_FFI_EXPORT
void bm2_exit(int32_t code) {
  /* Flush stdio (println output) but skip atexit handlers: the MoonBit
   * runtime registers one that would override our exit code. */
  fflush(NULL);
  _exit(code);
}

MOONBIT_FFI_EXPORT
int32_t bm2_write_fd(int32_t fd, moonbit_bytes_t data) {
  return write_all(fd, data, (size_t)Moonbit_array_length(data));
}
