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
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/statvfs.h>
#include <netinet/in.h>
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
int32_t subproc_spawn(moonbit_bytes_t bun_path, moonbit_bytes_t script,
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
    /* Empty out/err paths (a bare NUL terminator) mean "inherit the
     * parent's stdout/stderr" — used by the CLI to run tools like moon
     * with their output shown directly on the terminal. */
    if (Moonbit_array_length(out_path) > 1) {
      if (redirect_fd((char *)out_path, STDOUT_FILENO) != 0) _exit(126);
    }
    if (Moonbit_array_length(err_path) > 1) {
      if (redirect_fd((char *)err_path, STDERR_FILENO) != 0) _exit(126);
    }
    /* script is a NUL-terminated cstr. The first entry is the single
     * argument of a managed app; extra argv entries may follow, separated
     * by NUL, so the CLI can run commands with arguments (moon update,
     * moon install ...). An empty script means no arguments at all. */
    int argc;
    size_t slen = Moonbit_array_length(script);
    if (slen <= 1) {
      argc = 1;
    } else {
      argc = 2;
      for (size_t i = 0; i + 1 < slen; i++) {
        if (script[i] == 0) argc++;
      }
    }
    char **argv = malloc(sizeof(char *) * (size_t)(argc + 1));
    if (argv == NULL) _exit(126);
    argv[0] = (char *)bun_path;
    if (argc > 1) {
      char *p = (char *)script;
      char *end = p + slen;
      int idx = 1;
      while (p < end && *p != 0) {
        argv[idx++] = p;
        p += strlen(p) + 1;
      }
      argv[idx] = NULL;
    } else {
      argv[1] = NULL;
    }
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
int32_t subproc_waitpid(int32_t pid, int32_t nohang, moonbit_bytes_t out) {
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
int32_t subproc_kill_pg(int32_t pgid, int32_t sig) {
  return kill(-(pid_t)pgid, sig) == 0 ? 0 : -errno;
}

MOONBIT_FFI_EXPORT
int32_t subproc_kill0(int32_t pid) {
  return kill((pid_t)pid, 0) == 0 ? 0 : -errno;
}

/* utime + stime of a process, in clock ticks, from /proc/<pid>/stat, or -1
 * when the process is gone. The comm field is parenthesised and may contain
 * spaces, so parsing restarts after the last ')': field 3 is the state
 * character, then ppid (4) ... utime (14), stime (15). */
MOONBIT_FFI_EXPORT
int64_t subproc_read_cpu_ticks(int32_t pid) {
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  FILE *f = fopen(path, "r");
  if (f == NULL) return -1;
  char buf[2048];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  if (n == 0) return -1;
  buf[n] = 0;
  char *close_paren = strrchr(buf, ')');
  if (close_paren == NULL) return -1;
  char *p = close_paren + 1;
  while (*p == ' ') p++;
  if (*p == 0) return -1;
  p++; /* the state character */
  long long vals[12];
  int idx = 0;
  while (*p != 0 && idx < 12) {
    while (*p == ' ') p++;
    if (*p == 0) break;
    vals[idx++] = strtoll(p, &p, 10);
  }
  if (idx < 12) return -1;
  return (int64_t)(vals[10] + vals[11]);
}

/* Clock ticks per second, the divisor that turns cpu ticks into seconds. */
MOONBIT_FFI_EXPORT
int32_t subproc_clk_tck(void) {
  long value = sysconf(_SC_CLK_TCK);
  return value > 0 ? (int32_t)value : 100;
}

/* Host name, so notifications can say which machine they came from. */
MOONBIT_FFI_EXPORT
int32_t subproc_hostname(moonbit_bytes_t buf, int32_t cap) {
  if (cap <= 0) return -EINVAL;
  if (gethostname((char *)buf, (size_t)cap) != 0) return -errno;
  buf[cap - 1] = 0;
  return (int32_t)strlen((char *)buf);
}

MOONBIT_FFI_EXPORT
int32_t subproc_getpid(void) {
  return (int32_t)getpid();
}

/* VmRSS in kB from /proc/<pid>/status, or -1 when unavailable. */
MOONBIT_FFI_EXPORT
int32_t subproc_read_rss_kb(int32_t pid) {
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
void subproc_sleep_ms(int32_t ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
}

/* Close a pidfd or lock fd. */
MOONBIT_FFI_EXPORT
int32_t subproc_close(int32_t fd) {
  return close(fd) == 0 ? 0 : -errno;
}

/* Local-time components of epoch_ms: year, month(1-12), day(1-28+),
 * weekday(0=Sunday..6), hour(0-23), minute(0-59). */
MOONBIT_FFI_EXPORT
int32_t subproc_local_parts(int64_t epoch_ms, int32_t out[6]) {
  time_t secs = (time_t)(epoch_ms / 1000);
  struct tm tm;
  if (localtime_r(&secs, &tm) == NULL) return -1;
  out[0] = tm.tm_year + 1900;
  out[1] = tm.tm_mon + 1;
  out[2] = tm.tm_mday;
  out[3] = tm.tm_wday;
  out[4] = tm.tm_hour;
  out[5] = tm.tm_min;
  return 0;
}

/* One-minute load average, or -1.0 when unavailable. */
MOONBIT_FFI_EXPORT
double subproc_load_1m(void) {
  double loads[1];
  if (getloadavg(loads, 1) != 1) return -1.0;
  return loads[0];
}

/* Free space on the filesystem holding path, in KiB, or -1 on error. */
MOONBIT_FFI_EXPORT
int64_t subproc_disk_free_kb(const char *path) {
  struct statvfs fs;
  if (statvfs(path, &fs) != 0) return -1;
  return (int64_t)fs.f_bavail * ((int64_t)fs.f_bsize / 1024);
}

/* Probe whether a cluster app's listener enables SO_REUSEPORT, by asking
 * the kernel instead of reading app code:
 *   step 1: plain bind (SO_REUSEADDR only)  -> port free means not listening
 *   step 2: bind with SO_REUSEADDR|SO_REUSEPORT -> joinable means the
 *           existing listener shares; EADDRINUSE means it is exclusive.
 * Returns 0 (port free, app not listening yet), 1 (shared, reusePort on),
 * 2 (held exclusively, reusePort missing), or -errno. */
MOONBIT_FFI_EXPORT
int32_t subproc_probe_reuseport(int32_t port) {
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  int one = 1;
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -errno;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  int rc = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
  int err = errno;
  close(fd);
  if (rc == 0) return 0;
  if (err != EADDRINUSE) return -err;
  fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -errno;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
  rc = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
  err = errno;
  close(fd);
  if (rc == 0) return 1;
  if (err == EADDRINUSE) return 2;
  return -err;
}

/*
 * pidfd: a kernel handle pinned to one process. Unlike a raw pid it never
 * gets reused for a different process, so exit detection and liveness stay
 * correct even for adopted (non-child) instances. Requires Linux >= 5.3.
 */
MOONBIT_FFI_EXPORT
int32_t subproc_pidfd_open(int32_t pid) {
  int fd = (int)syscall(SYS_pidfd_open, (pid_t)pid, 0);
  return fd < 0 ? -errno : fd;
}

/* Like subproc_waitpid but through a pidfd (waitid P_PIDFD); same output
 * layout. waitid reports si_status raw (exit code or signal number), so it
 * is converted here to the waitpid-compatible wait status encoding. */
MOONBIT_FFI_EXPORT
int32_t subproc_wait_pidfd(int32_t fd, int32_t nohang, moonbit_bytes_t out) {
  siginfo_t info;
  memset(&info, 0, sizeof(info));
  int flags = WEXITED | (nohang ? WNOHANG : 0);
  int rc = waitid(P_PIDFD, (id_t)fd, &info, flags);
  int32_t vals[3];
  if (rc != 0) {
    vals[0] = -1;
    vals[1] = 0;
    vals[2] = (int32_t)errno;
  } else if (info.si_pid == 0) {
    vals[0] = 0;
    vals[1] = 0;
    vals[2] = 0;
  } else {
    vals[0] = (int32_t)info.si_pid;
    int32_t raw;
    if (info.si_code == CLD_EXITED) {
      raw = (int32_t)(info.si_status & 0xff) << 8;
    } else {
      raw = (int32_t)info.si_status & 0x7f;
    }
    vals[1] = raw;
    vals[2] = 0;
  }
  memcpy(out, vals, sizeof(vals));
  return 0;
}

/* 1 while the pidfd's process is alive, 0 once it has exited, -errno. */
MOONBIT_FFI_EXPORT
int32_t subproc_pidfd_alive(int32_t fd) {
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int rc;
  do {
    rc = poll(&pfd, 1, 0);
  } while (rc < 0 && errno == EINTR);
  if (rc < 0) return -errno;
  return rc == 0 ? 1 : 0;
}

MOONBIT_FFI_EXPORT
int32_t subproc_getuid(void) {
  return (int32_t)getuid();
}

/* Kernel name from uname(2), e.g. "Linux", for platform gating. */
MOONBIT_FFI_EXPORT
int32_t subproc_uname(moonbit_bytes_t buf, int32_t cap) {
  struct utsname uts;
  if (uname(&uts) != 0) return -errno;
  size_t n = strlen(uts.sysname);
  if ((int32_t)n >= cap) return -ENAMETOOLONG;
  memcpy(buf, uts.sysname, n + 1);
  return (int32_t)n;
}

/* ---------------- process helpers ---------------- */

MOONBIT_FFI_EXPORT
int32_t subproc_self_exe(moonbit_bytes_t buf, int32_t cap) {
  ssize_t n = readlink("/proc/self/exe", (char *)buf, (size_t)cap - 1);
  if (n < 0) return -errno;
  buf[n] = 0;
  return (int32_t)n;
}

MOONBIT_FFI_EXPORT
void subproc_exit(int32_t code) {
  /* Flush stdio (println output) but skip atexit handlers: the MoonBit
   * runtime registers one that would override our exit code. */
  fflush(NULL);
  _exit(code);
}

/* Bounded write used by eprintln; same poll-guarded loop as fsx, kept local
 * so the two stubs stay independently linkable. */
static int subproc_write_all(int fd, const uint8_t *data, size_t len) {
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

MOONBIT_FFI_EXPORT
int32_t subproc_write_fd(int32_t fd, moonbit_bytes_t data) {
  return subproc_write_all(fd, data, (size_t)Moonbit_array_length(data));
}
