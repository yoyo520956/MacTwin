//
//  MacTwin-Bridging-Header.h
//  ObjC/C ↔ Swift 桥接
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/mman.h>
#import <dlfcn.h>
#import <errno.h>
#import <unistd.h>

// ShimBridge.c —— 防崩 shim
void *mactwin_shim_lookup(const char *name);
int32_t mactwin_last_exit_code(void);
void    mactwin_set_exit_code(int32_t code);
int     mactwin_exit_was_called(void);
void    mactwin_reset_state(void);
int     mactwin_notes_copy(char *buf, int bufsize);
#import <fcntl.h>

// 崩溃守护
void mactwin_install_crash_guard(const char *logPath);
int  mactwin_read_crash(char *buf, int bufsize);
void mactwin_clear_crash(void);
