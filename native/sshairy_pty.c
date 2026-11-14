// A single-threaded PTY owner. The Flutter process never forks itself.
// stdin: [type:u8, length:u32be, payload], type 1=input, 2=cols:u16be/rows:u16be, 3=close.
// stdout is raw terminal bytes; stderr emits R\n after exec succeeds, or E\n on startup failure.
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#else
#include <dirent.h>
#endif
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

#define CAPACITY 65536
static volatile sig_atomic_t interrupted;
static void interrupt(int signal_number) { (void)signal_number; interrupted = 1; }
static int nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static int64_t milliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) return 0;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static unsigned u32(const unsigned char *p) {
  return ((unsigned)p[0] << 24) | ((unsigned)p[1] << 16) | ((unsigned)p[2] << 8) | p[3];
}
static int dimension(const char *value) {
  char *end = NULL;
  long number = strtol(value, &end, 10);
  return end && *end == '\0' && number > 0 && number <= 32767 ? (int)number : 0;
}
static int status_code(int status) {
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}
static void signal_owned(pid_t child, int master, int sig) {
  // Keep the leader unreaped until cleanup, so its session id cannot be reused by another application.
  pid_t foreground = tcgetpgrp(master);
  if (foreground > 0 && getsid(foreground) == child) kill(-foreground, sig);
  kill(-child, sig);
  kill(child, sig);
}
static void signal_jobs(pid_t session, int sig) {
  // Interactive jobs may each own a process group; only this helper's new session is eligible.
#ifdef __APPLE__
  int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t bytes = 0;
  if (sysctl(mib, 4, NULL, &bytes, NULL, 0) < 0) return;
  struct kinfo_proc *processes = malloc(bytes);
  if (!processes) return;
  if (sysctl(mib, 4, processes, &bytes, NULL, 0) == 0) {
    for (size_t i = 0; i < bytes / sizeof(*processes); ++i) {
      pid_t pid = processes[i].kp_proc.p_pid;
      if (pid > 0 && getsid(pid) == session) kill(pid, sig);
    }
  }
  free(processes);
#else
  DIR *directory = opendir("/proc");
  if (!directory) return;
  struct dirent *entry;
  while ((entry = readdir(directory))) {
    char *end;
    long pid = strtol(entry->d_name, &end, 10);
    if (*end == '\0' && pid > 0 && getsid((pid_t)pid) == session) kill((pid_t)pid, sig);
  }
  closedir(directory);
#endif
}

int main(int argc, char **argv) {
  if (argc < 6 || strcmp(argv[4], "--") != 0 || argv[5][0] != '/') {
    fputs("E\n", stderr);
    return 125;
  }
  struct winsize size;
  memset(&size, 0, sizeof(size));
  size.ws_col = (unsigned short)dimension(argv[1]);
  size.ws_row = (unsigned short)dimension(argv[2]);
  if (!size.ws_col || !size.ws_row) { fputs("E\n", stderr); return 125; }
  signal(SIGPIPE, SIG_IGN);
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = interrupt;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGHUP, &action, NULL);
  int master = -1, slave = -1, errors[2] = {-1, -1};
  if (openpty(&master, &slave, NULL, NULL, &size) < 0 || pipe(errors) < 0) goto startup_failed;
  if (fcntl(errors[1], F_SETFD, FD_CLOEXEC) < 0) goto startup_failed;
  pid_t child = fork();
  if (child < 0) goto startup_failed;
  if (child == 0) {
    int error;
    close(errors[0]);
    close(master);
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 ||
        dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 || dup2(slave, STDERR_FILENO) < 0 ||
        (argv[3][0] && chdir(argv[3]) < 0)) goto child_failed;
    if (slave > STDERR_FILENO) close(slave);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    if (setenv("TERM", "xterm-256color", 0) < 0 || setenv("COLORTERM", "truecolor", 0) < 0) goto child_failed;
    execv(argv[5], argv + 5);
  child_failed:
    error = errno;
    while (write(errors[1], &error, sizeof(error)) < 0 && errno == EINTR) {}
    _exit(127);
  }
  close(slave); slave = -1;
  close(errors[1]); errors[1] = -1;
  int exec_error;
  ssize_t launch = -1;
  int64_t startup_at = milliseconds();
  for (;;) {
    if (interrupted || milliseconds() - startup_at >= 5000) break;
    struct pollfd ready = {errors[0], POLLIN, 0};
    int result = poll(&ready, 1, 20);
    if (result < 0 && errno != EINTR) break;
    if (result > 0 && ready.revents & (POLLIN | POLLHUP)) {
      launch = read(errors[0], &exec_error, sizeof(exec_error));
      if (launch < 0 && errno == EINTR) continue;
      break;
    }
  }
  close(errors[0]); errors[0] = -1;
  if (launch != 0) {
    signal_owned(child, master, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    goto startup_failed;
  }
  if (nonblocking(master) < 0 || nonblocking(STDIN_FILENO) < 0 || nonblocking(STDOUT_FILENO) < 0) {
    signal_owned(child, master, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    goto startup_failed;
  }
  if (write(STDERR_FILENO, "R\n", 2) != 2) {
    signal_owned(child, master, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    close(master);
    return 125;
  }
  unsigned char input[CAPACITY + 5], pending[CAPACITY], output[CAPACITY];
  size_t input_n = 0, pending_n = 0, output_n = 0;
  int status = 0, dead = 0, eof = 0, closing = 0, killed = 0, failed = 0;
  int64_t close_at = 0, dead_at = 0, eof_at = 0;
  for (;;) {
    int64_t now = milliseconds();
    if (!dead) {
      siginfo_t ended;
      memset(&ended, 0, sizeof(ended));
      int observed = waitid(P_PID, (id_t)child, &ended, WEXITED | WNOHANG | WNOWAIT);
      if (observed == 0 && ended.si_pid == child) { dead = 1; dead_at = now; }
      else if (observed < 0 && errno != EINTR) { failed = 1; interrupted = 1; }
    }
    if (interrupted && !closing) { closing = 1; close_at = now; }
    if (closing && !killed) { signal_owned(child, master, SIGHUP); signal_jobs(child, SIGHUP); killed = 1; }
    if (closing && now - close_at >= 500 && killed == 1) {
      signal_owned(child, master, SIGKILL); signal_jobs(child, SIGKILL); killed = 2;
    }
    // Stop leftover jobs, then drain the terminal to EOF even if its consumer was paused.
    if (dead && !closing && now - dead_at >= 300 && !killed) { signal_jobs(child, SIGHUP); killed = 1; }
    if (dead && !closing && now - dead_at >= 800 && killed == 1) { signal_jobs(child, SIGKILL); killed = 2; }
    if (closing) { output_n = 0; pending_n = 0; input_n = 0; }
    if (dead && eof && output_n == 0) break;
    struct pollfd watched[3];
    watched[0] = (struct pollfd){!closing && input_n < sizeof(input) ? STDIN_FILENO : -1, POLLIN, 0};
    short terminal_events = (!eof && (closing || output_n < sizeof(output)) ? POLLIN : 0) | (!closing && pending_n ? POLLOUT : 0);
    watched[1] = (struct pollfd){terminal_events ? master : -1, terminal_events, 0};
    watched[2] = (struct pollfd){output_n && !closing ? STDOUT_FILENO : -1, POLLOUT, 0};
    int ready = poll(watched, 3, 20);
    if (ready < 0) { if (errno == EINTR) continue; failed = 1; interrupted = 1; continue; }
    if (!closing && watched[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = read(STDIN_FILENO, input + input_n, sizeof(input) - input_n);
      if (n > 0) input_n += (size_t)n;
      else if (n == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) interrupted = 1;
    }
    while (!closing && input_n >= 5) {
      unsigned type = input[0], length = u32(input + 1);
      if (length > CAPACITY || (type != 1 && type != 2 && type != 3) ||
          (type == 2 && length != 4) || (type == 3 && length != 0)) { failed = 1; interrupted = 1; break; }
      if (input_n < length + 5) break;
      if (type == 1 && pending_n + length > sizeof(pending)) break;
      if (type == 1) { memcpy(pending + pending_n, input + 5, length); pending_n += length; }
      if (type == 2) {
        size.ws_col = (unsigned short)(((unsigned)input[5] << 8) | input[6]);
        size.ws_row = (unsigned short)(((unsigned)input[7] << 8) | input[8]);
        if (!size.ws_col || !size.ws_row || size.ws_col > 32767 || size.ws_row > 32767 || ioctl(master, TIOCSWINSZ, &size) < 0) {
          if (!dead) { failed = 1; interrupted = 1; }
        }
      }
      if (type == 3) interrupted = 1;
      input_n -= length + 5;
      memmove(input, input + length + 5, input_n);
    }
    if (!closing && pending_n && watched[1].revents & POLLOUT) {
      ssize_t n = write(master, pending, pending_n);
      if (n > 0) { pending_n -= (size_t)n; memmove(pending, pending + n, pending_n); }
      else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        if (errno != EIO) failed = 1;
        interrupted = 1;
      }
    }
    if (!eof && watched[1].revents & (POLLIN | POLLHUP | POLLERR)) {
      unsigned char discard[8192];
      unsigned char *where = closing ? discard : output + output_n;
      size_t room = closing ? sizeof(discard) : sizeof(output) - output_n;
      if (room) {
        ssize_t n = read(master, where, room);
        if (n > 0 && !closing) output_n += (size_t)n;
        else if (n == 0 || (n < 0 && errno == EIO)) eof = 1;
        else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) { failed = 1; interrupted = 1; eof = 1; }
      }
    }
    if (!closing && output_n && watched[2].revents & (POLLOUT | POLLERR | POLLHUP)) {
      ssize_t n = write(STDOUT_FILENO, output, output_n);
      if (n > 0) { output_n -= (size_t)n; memmove(output, output + n, output_n); }
      else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) { interrupted = 1; output_n = 0; }
    }
    // PTY EOF can precede waitid observing the child. Preserve queued tail output in that race.
    if (eof && !dead && !closing) {
      if (!eof_at) eof_at = now;
      if (now - eof_at >= 500) signal_owned(child, master, SIGHUP);
      if (now - eof_at >= 1000) signal_owned(child, master, SIGKILL);
    }
  }
  // The PTY belongs solely to this helper; final hangup cannot affect other app sessions.
  signal_owned(child, master, SIGKILL);
  signal_jobs(child, SIGKILL);
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
  close(master);
  return failed ? 125 : status_code(status);

startup_failed:
  if (master >= 0) close(master);
  if (slave >= 0) close(slave);
  if (errors[0] >= 0) close(errors[0]);
  if (errors[1] >= 0) close(errors[1]);
  fputs("E\n", stderr);
  return 125;
}
