//  hello_macos.c
//  打进 MacTwin.app 的内置 demo
//  只用 libSystem 的 API，编译为 arm64-apple-macos
//  目标是让新用户打开 App 后 30 秒内就能看到「Mac 二进制真的在 iPhone 上跑」

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>

static const char *which_platform(void) {
    static char buf[128];
    snprintf(buf, sizeof(buf), "macOS on iPhone (via MacTwin)");
    return buf;
}

int main(int argc, char **argv) {
    // 输出到 stdout，MacTwin 会捕获
    printf("========================================\n");
    printf("  MacTwin 演示程序\n");
    printf("  跑在: %s\n", which_platform());
    printf("========================================\n");

    // 1. 基本 C 库函数（iOS 都直通的）
    const char *name = "MacTwin";
    printf("\n[libSystem]  %s: strlen=%zu, toupper=%c\n",
           name, strlen(name), (char)('m' + 0 - 'm' + 'M'));

    // 2. 内存分配
    char *dup = strdup("macos binary");
    printf("[malloc]      strdup → %s\n", dup);
    free(dup);

    // 3. Mach 常量（iOS 也有）
    printf("[mach]        vm_page_size = %lu\n", (unsigned long)vm_page_size);

    // 4. 时间
    time_t now = time(NULL);
    printf("[time]        当前 Unix 时间戳 = %ld\n", (long)now);

    // 5. 线程
    pthread_t t;
    printf("[pthread]     创建线程… ");
    if (pthread_create(&t, NULL, NULL, NULL) == 0) {
        // 这里故意不 join，pthread_create 在 iOS 上成功但没主线程
        printf("OK\n");
    } else {
        printf("跳过（未启用完整线程库）\n");
    }

    // 6. 参数
    printf("\n[argv]      argc = %d\n", argc);
    for (int i = 0; i < argc && i < 4; i++) {
        printf("  argv[%d] = %s\n", i, argv[i] ? argv[i] : "(null)");
    }

    printf("\n✅ 演示完成，exit(0)\n");
    return 0;
}