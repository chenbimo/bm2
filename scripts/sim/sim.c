// sim.c — reproduce bm2d's fd layout + c_spawn behavior, then exec bun.
// Usage: sim <mode>
//   mode bits: +1 flock fd3, +2 ptmx fd5, +4 unix socket fd8, +8 pidfd fd6/7/10
//   e.g. "sim 15" = all fds, "sim 0" = none.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <sys/syscall.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
  int mode = argc > 1 ? atoi(argv[1]) : 15;
  if (mode & 1) {
    int lk = open("/home/chensuiyi/.bm2/bm2d.lock", O_RDWR);
    if (lk >= 0) flock(lk, LOCK_EX);
  }
  if (mode & 2) {
    int p = open("/dev/ptmx", O_RDWR);
  }
  if (mode & 4) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, "/tmp/sim.sock");
    unlink("/tmp/sim.sock");
    bind(s, (struct sockaddr *)&addr, sizeof(addr));
    listen(s, 8);
  }
  if (mode & 8) {
    int p1 = syscall(SYS_pidfd_open, getpid(), 0);
    int p2 = syscall(SYS_pidfd_open, getpid(), 0);
    int p3 = syscall(SYS_pidfd_open, getpid(), 0);
  }

  pid_t pid = fork();
  if (pid == 0) {
    setsid();
    if (chdir("/home/chensuiyi/projects/befly-api-test") != 0) _exit(126);
    int dn = open("/dev/null", O_RDONLY);
    if (dn >= 0) { dup2(dn, 0); close(dn); }
    int o = open("/tmp/sim.out", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int e = open("/tmp/sim.err", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (o < 0 || e < 0) _exit(126);
    dup2(o, 1); dup2(e, 2);
    char *envp[] = {
      "PATH=/home/chensuiyi/.local/bin:/home/chensuiyi/.bun/bin:/usr/bin:/bin",
      "HOME=/home/chensuiyi",
      "NODE_ENV=development",
      "BEFLY_TEST_MYSQL_URL=sh-cynosdbmysql-grp-md1m7gwq.sql.tencentcdb.com",
      "BEFLY_TEST_MYSQL_PASS=abc123!@#",
      "BM2_APP_NAME=api",
      "BM2_INSTANCE_ID=2",
      "BM2_APP_INSTANCE=2",
      "BM2_APP_PORT=3002",
      NULL,
    };
    char *argv[] = {"bun", "index.js", NULL};
    execvpe("bun", argv, envp);
    _exit(127);
  }
  int status = 0;
  waitpid(pid, &status, 0);
  FILE *f = fopen("/tmp/sim.rc", "w");
  fprintf(f, "mode=%d rc=%d\n", mode, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
  fclose(f);
  return 0;
}
