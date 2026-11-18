//
//  ShimBridge.c
//  MacTwin — 防崩 shim（用 C 实现，避免 Swift/C 互操作的类型陷阱）
//
//  目标 macOS 二进制调用 exit()/abort() 时，如果落到真实实现，会直接终结
//  我们的 App。这里的 shim 把「终止进程」改成「终止当前线程」，
//  App 存活，输出和错误都能正常送回 UI。
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <stdint.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>

// ── 与 Swift 共享的状态 ──
static volatile int32_t g_exit_code = 0;
static volatile int      g_exit_called = 0;

// 最近被拦截的调用（简单环形记录，供 UI 显示）
#define MAX_NOTES 16
static char g_notes[MAX_NOTES][64];
static int  g_note_count = 0;
static pthread_mutex_t g_note_lock = PTHREAD_MUTEX_INITIALIZER;

static void note(const char *what) {
    pthread_mutex_lock(&g_note_lock);
    if (g_note_count < MAX_NOTES) {
        strncpy(g_notes[g_note_count], what, sizeof(g_notes[0]) - 1);
        g_notes[g_note_count][sizeof(g_notes[0]) - 1] = '\0';
        g_note_count++;
    }
    pthread_mutex_unlock(&g_note_lock);
}

// ── 对外查询接口 ──

int32_t mactwin_last_exit_code(void) { return g_exit_code; }

// main 正常返回时由 Swift 侧写回
void mactwin_set_exit_code(int32_t code) {
    g_exit_code = code;
    g_exit_called = 1;
}
int     mactwin_exit_was_called(void) { return g_exit_called; }

void mactwin_reset_state(void) {
    g_exit_code = 0;
    g_exit_called = 0;
    pthread_mutex_lock(&g_note_lock);
    g_note_count = 0;
    pthread_mutex_unlock(&g_note_lock);
}

int mactwin_notes_copy(char *buf, int bufsize) {
    pthread_mutex_lock(&g_note_lock);
    int written = 0;
    buf[0] = '\0';
    for (int i = 0; i < g_note_count; i++) {
        int need = (int)strlen(g_notes[i]) + 2;
        if (written + need >= bufsize) break;
        if (written) { buf[written++] = '\n'; }
        strcpy(buf + written, g_notes[i]);
        written += (int)strlen(g_notes[i]);
    }
    pthread_mutex_unlock(&g_note_lock);
    return written;
}

// ── shim 本体 ──

void mactwin_shim_exit(int32_t code) {
    g_exit_code = code;
    g_exit_called = 1;
    note("exit() 被拦截");
    pthread_exit(NULL);
    // pthread_exit 不返回；万一返回，进入死循环而不是回落给调用方
    for (;;) { sleep(100); }
}

void mactwin_shim_abort(void) {
    note("abort() 被拦截");
    mactwin_shim_exit(134);
    for (;;) { sleep(100); }
}

int32_t mactwin_shim_fork(void) {
    note("fork() 返回 ENOSYS（iOS 不支持）");
    errno = ENOSYS;
    return -1;
}

int32_t mactwin_shim_execve(const char *path, char *const argv[], char *const envp[]) {
    (void)path; (void)argv; (void)envp;
    note("execve() 返回 ENOSYS（iOS 不支持）");
    errno = ENOSYS;
    return -1;
}

int32_t mactwin_shim_system(const char *cmd) {
    (void)cmd;
    note("system() 返回 ENOSYS");
    errno = ENOSYS;
    return -1;
}

void *mactwin_shim_dyld_stub_binder(void) {
    note("dyld_stub_binder：有符号漏绑");
    return NULL;
}

// AppKit 占位（P5 换成真实现）
int32_t mactwin_shim_NSApplicationMain(int32_t argc, char **argv) {
    (void)argc; (void)argv;
    note("NSApplicationMain：GUI 层尚未实现");
    return 0;
}

// ── 按名字取地址（Swift 侧唯一入口）──

void *mactwin_shim_lookup(const char *name) {
    if (!name) return NULL;

    if (!strcmp(name, "exit"))              return (void *)mactwin_shim_exit;
    if (!strcmp(name, "_exit"))             return (void *)mactwin_shim_exit;
    if (!strcmp(name, "abort"))             return (void *)mactwin_shim_abort;
    if (!strcmp(name, "__assert_rtn"))      return (void *)mactwin_shim_abort;
    if (!strcmp(name, "__assert"))          return (void *)mactwin_shim_abort;
    if (!strcmp(name, "__stack_chk_fail"))  return (void *)mactwin_shim_abort;
    if (!strcmp(name, "fork"))              return (void *)mactwin_shim_fork;
    if (!strcmp(name, "vfork"))             return (void *)mactwin_shim_fork;
    if (!strcmp(name, "execve"))            return (void *)mactwin_shim_execve;
    if (!strcmp(name, "execv"))             return (void *)mactwin_shim_execve;
    if (!strcmp(name, "execvp"))            return (void *)mactwin_shim_execve;
    if (!strcmp(name, "system"))            return (void *)mactwin_shim_system;
    if (!strcmp(name, "dyld_stub_binder"))  return (void *)mactwin_shim_dyld_stub_binder;
    if (!strcmp(name, "NSApplicationMain")) return (void *)mactwin_shim_NSApplicationMain;

    return NULL;
}
// ── 崩溃守护（全 C，异步信号安全）──
static char *g_crash_path = NULL;
static volatile int g_crash_kind_code = 0;

static void crash_handler(int sig) {
    // 只用 async-signal-safe 函数：open/write/close/strncpy
    char buf[512];
    const char *name = "SIG???";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGILL:  name = "SIGILL";  break;
        default: break;
    }
    time_t t = time(NULL);
    int n = snprintf(buf, sizeof(buf),
                     "%s at %lld | exit_code=%d exit_called=%d\n",
                     name, (long long)t, g_exit_code, g_exit_called);
    if (n > 0 && g_crash_path) {
        int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            (void)!write(fd, buf, (size_t)n);
            close(fd);
        }
    }
    // 让默认处理接管（终止进程），但日志已留下
    signal(sig, SIG_DFL);
    raise(sig);
}

// Swift 侧安装
void mactwin_install_crash_guard(const char *logPath) {
    if (g_crash_path) free(g_crash_path);
    g_crash_path = logPath ? strdup(logPath) : NULL;
    if (logPath) {
        signal(SIGSEGV, crash_handler);
        signal(SIGBUS,  crash_handler);
        signal(SIGFPE,  crash_handler);
        signal(SIGILL,  crash_handler);
    }
}

// 最近一次崩溃日志（Swift 读）
int mactwin_read_crash(char *buf, int bufsize) {
    if (!g_crash_path || !buf || bufsize <= 0) return 0;
    int fd = open(g_crash_path, O_RDONLY, 0);
    if (fd < 0) return 0;
    int n = read(fd, buf, (size_t)(bufsize - 1));
    close(fd);
    if (n < 0) n = 0;
    buf[n] = '\0';
    return n;
}

void mactwin_clear_crash(void) {
    if (g_crash_path) {
        int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) close(fd);
    }
}
