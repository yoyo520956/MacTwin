//  hello_gui_macos.m
//  MacTwin 的 GUI 演示：一个真的 AppKit 程序
//
//  编译（macOS）：
//    xcrun clang -target arm64-apple-macos13 -framework Cocoa -o hello-gui hello_gui_macos.m
//
//  在 iPhone 上：MacTwin 加载它 → 我们的 AppKitShim 把 NSWindow 映射成 UIWindow
//  → 屏幕上就出现这个程序的窗口。这验证了「看得到软件界面」。

#import <Cocoa/Cocoa.h>

@interface MTDemoDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, assign) NSInteger ticks;
@end

@implementation MTDemoDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSRect frame = NSMakeRect(0, 0, 320, 240);

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"MacTwin — 真 macOS 程序在 iPhone 上运行"];

    NSView *content = [[NSView alloc] initWithFrame:frame];
    [content setWantsLayer:YES];
    [content setBackgroundColor:[NSColor colorWithCalibratedRed:0.12
                                                         green:0.16
                                                          blue:0.24
                                                         alpha:1.0]];
    [self.window setContentView:content];

    // 三个标签，证明 NSString / NSColor / NSFont 走的是同一个 Foundation
    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 160, 280, 30)];
    [title setStringValue:@"Hello from macOS"];
    [title setFont:[NSFont boldSystemFontOfSize:20]];
    [title setTextColor:[NSColor whiteColor]];
    [title setBackgroundColor:[NSColor clearColor]];
    [title setBordered:NO];
    [content addSubview:title];

    NSTextField *sub = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 120, 280, 20)];
    [sub setStringValue:@"这个窗口由未修改的 arm64 macOS 二进制绘制"];
    [sub setFont:[NSFont systemFontOfSize:12]];
    [sub setTextColor:[NSColor colorWithCalibratedRed:0.6 green:0.75 blue:0.95 alpha:1.0]];
    [sub setBackgroundColor:[NSColor clearColor]];
    [sub setBordered:NO];
    [content addSubview:sub];

    self.label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 80, 280, 20)];
    [self.label setStringValue:@"tick 0"];
    [self.label setFont:[NSFont systemFontOfSize:11]];
    [self.label setTextColor:[NSColor colorWithCalibratedRed:0.5 green:1.0 blue:0.7 alpha:1.0]];
    [self.label setBackgroundColor:[NSColor clearColor]];
    [self.label setBordered:NO];
    [content addSubview:self.label];

    [self.window makeKeyAndOrderFront:nil];

    // 定时器：证明 runloop 也活着
    [NSTimer scheduledTimerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(tick:)
                                   userInfo:nil
                                    repeats:YES];

    NSLog(@"[MacTwin demo] 窗口已创建：%@", [self.window title]);
}

- (void)tick:(NSTimer *)timer {
    self.ticks += 1;
    [self.label setStringValue:[NSString stringWithFormat:@"tick %ld — runloop 正常",
                                (long)self.ticks]];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        MTDemoDelegate *delegate = [[MTDemoDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];

        // 防止 delegate 被提前释放
        (void)delegate;
    }
    return 0;
}
