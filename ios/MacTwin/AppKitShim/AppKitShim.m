//  AppKitShim.m
//  MacTwin — 最小 AppKit 兼容层
//
//  为什么只需要 AppKit：
//    Foundation(NSString/NSArray/NSData/NSURL…) 在 iOS 上本来就有，
//    CoreGraphics / CoreText / CoreAnimation / Metal 也都有。
//    真正缺的只有 AppKit —— 这一层把它映射到 UIKit。
//
//  坐标：AppKit 原点在左下，UIKit 在左上 → 根视图统一翻 Y 轴。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 运行时桥

// NSView ↔ UIView 的对应表（用关联对象反向查）
static const void *kMTUIViewKey   = &kMTUIViewKey;
static const void *kMTNSViewKey   = &kMTNSViewKey;
static const void *kMTWindowKey   = &kMTWindowKey;

#pragma mark - NSResponder

@interface NSResponder : NSObject
@property (nonatomic, weak) NSResponder *nextResponder;
@end

@implementation NSResponder
@end

#pragma mark - NSColor（先声明，NSView 要用）

@interface NSColor : NSObject
@property (nonatomic, readonly) CGFloat red, green, blue, alpha;
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)blackColor;
+ (NSColor *)whiteColor;
+ (NSColor *)clearColor;
+ (NSColor *)windowBackgroundColor;
- (UIColor *)mt_uiColor;
@end

@implementation NSColor {
    CGFloat _r, _g, _b, _a;
}
@synthesize red = _r, green = _g, blue = _b, alpha = _a;

+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    NSColor *c = [NSColor new];
    c->_r = r; c->_g = g; c->_b = b; c->_a = a;
    return c;
}
+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [self colorWithCalibratedRed:r green:g blue:b alpha:a];
}
+ (NSColor *)blackColor  { return [self colorWithCalibratedRed:0 green:0 blue:0 alpha:1]; }
+ (NSColor *)whiteColor  { return [self colorWithCalibratedRed:1 green:1 blue:1 alpha:1]; }
+ (NSColor *)clearColor  { return [self colorWithCalibratedRed:0 green:0 blue:0 alpha:0]; }
+ (NSColor *)windowBackgroundColor {
    return [self colorWithCalibratedRed:0.93 green:0.93 blue:0.93 alpha:1];
}
- (UIColor *)mt_uiColor {
    return [UIColor colorWithRed:_r green:_g blue:_b alpha:_a];
}
@end

#pragma mark - NSView

@class NSView, NSWindow;

// UIKit 宿主：把 drawRect: 转发给 NSView，并翻转坐标
@interface MTViewHost : UIView
@property (nonatomic, weak) NSView *nsView;
@end

@interface NSView : NSResponder
@property (nonatomic, strong) MTViewHost *host;
@property (nonatomic, weak) NSView *superview;
@property (nonatomic, copy) NSArray<NSView *> *subviews;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) CGRect bounds;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, assign) CGFloat alphaValue;
@property (nonatomic, assign) BOOL hidden;
@property (nonatomic, assign) BOOL wantsLayer;
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, readonly) NSWindow *window;
@property (nonatomic, assign) BOOL autoresizesSubviews;

- (instancetype)initWithFrame:(NSRect)frameRect;
- (instancetype)init;
- (void)addSubview:(NSView *)view;
- (void)removeFromSuperview;
- (void)setNeedsDisplay:(BOOL)flag;
- (void)setNeedsDisplayInRect:(NSRect)r;
- (void)drawRect:(NSRect)dirtyRect;
- (void)layout;
- (void)layoutSubtreeIfNeeded;
- (NSPoint)convertPoint:(NSPoint)p fromView:(NSView *)v;
- (NSPoint)convertPoint:(NSPoint)p toView:(NSView *)v;
- (BOOL)isFlipped;
@end

@implementation MTViewHost
- (void)drawRect:(CGRect)rect {
    NSView *v = self.nsView;
    if (v) {
        @try { [v drawRect:rect]; } @catch (NSException *e) { /* 不让绘图异常杀掉 App */ }
    }
}
@end

@implementation NSView {
    NSColor *_bgColor;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super init];
    if (self) {
        _host = [[MTViewHost alloc] initWithFrame:frameRect];
        _host.nsView = self;
        _host.layer.isGeometryFlipped = YES;   // AppKit 坐标：原点左下
        objc_setAssociatedObject(_host, kMTNSViewKey, self, OBJC_ASSOCIATION_ASSIGN);
        _alphaValue = 1.0;
        _autoresizesSubviews = YES;
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:CGRectZero]; }

- (CGRect)frame { return _host.frame; }
- (void)setFrame:(CGRect)f { _host.frame = f; }

- (CGRect)bounds { return _host.bounds; }
- (void)setBounds:(CGRect)b { _host.bounds = b; }

- (NSColor *)backgroundColor { return _bgColor; }
- (void)setBackgroundColor:(NSColor *)c {
    _bgColor = c;
    _host.backgroundColor = c ? [c mt_uiColor] : [UIColor clearColor];
}

- (CGFloat)alphaValue { return _host.alpha; }
- (void)setAlphaValue:(CGFloat)a { _host.alpha = a; }

- (BOOL)hidden { return _host.hidden; }
- (void)setHidden:(BOOL)h { _host.hidden = h; }

- (BOOL)wantsLayer { return _host.layer != nil; }
- (void)setWantsLayer:(BOOL)w { /* UIView 天然有 layer */ }

- (NSInteger)tag { return _host.tag; }
- (void)setTag:(NSInteger)t { _host.tag = t; }

- (CALayer *)layer { return _host.layer; }

- (NSWindow *)window {
    UIWindow *w = _host.window;
    return w ? objc_getAssociatedObject(w, kMTWindowKey) : nil;
}

- (NSView *)superview {
    UIView *sv = _host.superview;
    return sv ? objc_getAssociatedObject(sv, kMTNSViewKey) : nil;
}

- (NSArray<NSView *> *)subviews {
    NSMutableArray *arr = [NSMutableArray array];
    for (UIView *uv in _host.subviews) {
        id v = objc_getAssociatedObject(uv, kMTNSViewKey);
        if (v) [arr addObject:v];
    }
    return arr;
}
- (void)setSubviews:(NSArray<NSView *> *)v { /* 只读语义，忽略 */ }

- (void)addSubview:(NSView *)view {
    if (!view || !view.host) return;
    [_host addSubview:view.host];
}

- (void)removeFromSuperview { [_host removeFromSuperview]; }

- (void)setNeedsDisplay:(BOOL)flag { [_host setNeedsDisplay]; }
- (void)setNeedsDisplayInRect:(NSRect)r { [_host setNeedsDisplay]; }

- (void)drawRect:(NSRect)dirtyRect { /* 子类覆盖 */ }
- (void)layout { /* 子类覆盖 */ }
- (void)layoutSubtreeIfNeeded { [_host layoutIfNeeded]; }

- (BOOL)isFlipped { return YES; }

- (NSPoint)convertPoint:(NSPoint)p fromView:(NSView *)v { return p; }
- (NSPoint)convertPoint:(NSPoint)p toView:(NSView *)v { return p; }

@end

#pragma mark - NSWindow

typedef NS_OPTIONS(NSUInteger, NSWindowStyleMask) {
    NSWindowStyleMaskBorderless     = 0,
    NSWindowStyleMaskTitled         = 1 << 0,
    NSWindowStyleMaskClosable       = 1 << 1,
    NSWindowStyleMaskMiniaturizable = 1 << 2,
    NSWindowStyleMaskResizable      = 1 << 3,
};

@class NSView;

@interface NSWindow : NSResponder
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) BOOL isVisible;
@property (nonatomic, readonly) BOOL isKeyWindow;
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) id<UIWindowSceneDelegate> sceneDelegate;

- (instancetype)initWithContentRect:(CGRect)rect
                          styleMask:(NSWindowStyleMask)mask
                            backing:(NSUInteger)backing
                              defer:(BOOL)flag;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)orderFront:(id)sender;
- (void)orderOut:(id)sender;
- (void)center;
- (void)close;
- (void)setContentSize:(CGSize)size;
@end

@implementation NSWindow {
    NSString *_title;
    UIWindow *_uiWindow;
    NSView   *_contentViewShadow;
    BOOL      _visible;
}

- (instancetype)initWithContentRect:(CGRect)rect
                          styleMask:(NSWindowStyleMask)mask
                            backing:(NSUInteger)backing
                              defer:(BOOL)flag {
    self = [super init];
    if (!self) return nil;

    _uiWindow = [[UIWindow alloc] initWithFrame:rect];
    _uiWindow.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
    objc_setAssociatedObject(_uiWindow, kMTWindowKey, self, OBJC_ASSOCIATION_ASSIGN);

    NSView *cv = [[NSView alloc] initWithFrame:rect];
    cv.backgroundColor = [NSColor windowBackgroundColor];
    _contentViewShadow = cv;
    objc_setAssociatedObject(_uiWindow, kMTNSViewKey, cv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [_uiWindow addSubview:cv.host];

    // 默认 rootViewController，否则 iOS 13+ 不显示
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = _uiWindow.backgroundColor;
    [vc.view addSubview:cv.host];
    _uiWindow.rootViewController = vc;

    _frame = rect;
    return self;
}

- (NSView *)contentView { return _contentViewShadow; }
- (void)setContentView:(NSView *)v {
    if (!v) return;
    [_contentViewShadow.host removeFromSuperview];
    _contentViewShadow = v;
    [_uiWindow.rootViewController.view addSubview:v.host];
    objc_setAssociatedObject(_uiWindow, kMTNSViewKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString *)title { return _title ?: @""; }
- (void)setTitle:(NSString *)t { _title = [t copy]; }

- (CGRect)frame { return _uiWindow.frame; }
- (void)setFrame:(CGRect)f { _uiWindow.frame = f; _frame = f; }

- (BOOL)isVisible { return _visible; }
- (BOOL)isKeyWindow { return _uiWindow.isKeyWindow; }

- (void)makeKeyAndOrderFront:(id)sender {
    _visible = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_uiWindow makeKeyAndVisible];
    });
}

- (void)orderFront:(id)sender { [self makeKeyAndOrderFront:sender]; }

- (void)orderOut:(id)sender {
    _visible = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_uiWindow.hidden = YES;
    });
}

- (void)center { /* iOS 全屏，无需居中 */ }

- (void)close { [self orderOut:nil]; }

- (void)setContentSize:(CGSize)size {
    CGRect f = _uiWindow.frame;
    f.size = size;
    _uiWindow.frame = f;
    _contentViewShadow.frame = CGRectMake(0, 0, size.width, size.height);
}

@end

#pragma mark - NSApplication

@protocol NSApplicationDelegate <NSObject>
@optional
- (void)applicationDidFinishLaunching:(NSNotification *)n;
- (void)applicationWillTerminate:(NSNotification *)n;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(id)sender;
@end

@interface NSApplication : NSResponder
@property (nonatomic, weak) id<NSApplicationDelegate> delegate;
@property (nonatomic, readonly) NSArray<NSWindow *> *windows;
+ (NSApplication *)sharedApplication;
- (void)run;
- (void)stop:(id)sender;
- (void)terminate:(id)sender;
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)setActivationPolicy:(NSInteger)policy;
- (NSWindow *)mainWindow;
- (NSWindow *)keyWindow;
- (void)sendEvent:(id)event;
@end

@implementation NSApplication {
    NSMutableArray<NSWindow *> *_windows;
    BOOL _running;
}

@synthesize delegate = _delegate;

+ (NSApplication *)sharedApplication {
    static NSApplication *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [NSApplication new]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) _windows = [NSMutableArray array];
    return self;
}

- (NSArray<NSWindow *> *)windows { return [_windows copy]; }
- (NSWindow *)mainWindow { return _windows.firstObject; }
- (NSWindow *)keyWindow { return _windows.firstObject; }

- (void)run {
    _running = YES;

    // 在后台线程被调用：UI 交给主线程，本线程用 runloop 挂住
    dispatch_async(dispatch_get_main_queue(), ^{
        id<NSApplicationDelegate> d = self.delegate;
        if (d && [d respondsToSelector:@selector(applicationDidFinishLaunching:)]) {
            @try {
                [d applicationDidFinishLaunching:
                    [NSNotification notificationWithName:@"NSApplicationDidFinishLaunchingNotification"
                                                  object:self]];
            } @catch (NSException *e) {
                NSLog(@"[MacTwin] applicationDidFinishLaunching 抛异常: %@", e);
            }
        }
    });

    // 保持线程存活（runloop 空转，可被 stop 打断）
    while (_running) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
    }
}

- (void)stop:(id)sender { _running = NO; }
- (void)terminate:(id)sender { _running = NO; }
- (void)activateIgnoringOtherApps:(BOOL)flag { }
- (void)setActivationPolicy:(NSInteger)policy { }
- (void)sendEvent:(id)event { }

@end

#pragma mark - NSApplicationMain

// AppKit 程序的入口。macOS 上是 int NSApplicationMain(int, const char **)
int NSApplicationMain(int argc, const char **argv) {
    NSApplication *app = [NSApplication sharedApplication];
    [app run];
    return 0;
}

#pragma mark - 绘图函数

void NSRectFill(NSRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) CGContextFillRect(ctx, rect);
}

void NSRectFillUsingOperation(NSRect rect, NSUInteger op) {
    NSRectFill(rect);
}

void NSFrameRect(NSRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) CGContextStrokeRect(ctx, rect);
}

NSRect NSMakeRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return CGRectMake(x, y, w, h);
}
NSPoint NSMakePoint(CGFloat x, CGFloat y) { return CGPointMake(x, y); }
NSSize  NSMakeSize(CGFloat w, CGFloat h) { return CGSizeMake(w, h); }

#pragma mark - NSFont

@interface NSFont : NSObject
@property (nonatomic, assign) CGFloat pointSize;
@property (nonatomic, assign) BOOL bold;
+ (NSFont *)systemFontOfSize:(CGFloat)size;
+ (NSFont *)boldSystemFontOfSize:(CGFloat)size;
+ (NSFont *)fontWithName:(NSString *)name size:(CGFloat)size;
+ (NSFont *)monospacedSystemFontOfSize:(CGFloat)size weight:(CGFloat)weight;
- (UIFont *)mt_uiFont;
@end

@implementation NSFont
+ (NSFont *)systemFontOfSize:(CGFloat)size {
    NSFont *f = [NSFont new]; f.pointSize = size; f.bold = NO; return f;
}
+ (NSFont *)boldSystemFontOfSize:(CGFloat)size {
    NSFont *f = [NSFont new]; f.pointSize = size; f.bold = YES; return f;
}
+ (NSFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    return [self systemFontOfSize:size];
}
+ (NSFont *)monospacedSystemFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    NSFont *f = [NSFont new]; f.pointSize = size; f.bold = NO; return f;
}
- (UIFont *)mt_uiFont {
    CGFloat s = self.pointSize > 0 ? self.pointSize : 13;
    return self.bold ? [UIFont boldSystemFontOfSize:s] : [UIFont systemFontOfSize:s];
}
@end

#pragma mark - NSTextField

@interface NSTextField : NSView
@property (nonatomic, copy)   NSString *stringValue;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic, strong) NSColor *textColor;
@property (nonatomic, assign) BOOL bordered;
@property (nonatomic, assign) BOOL editable;
@property (nonatomic, assign) BOOL selectable;
@property (nonatomic, assign) NSInteger alignment;
@end

@implementation NSTextField {
    UILabel *_label;
    NSColor *_tfTextColor;
    NSFont *_font;
    BOOL _bordered;
    BOOL _editable;
    BOOL _selectable;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _label = [[UILabel alloc] initWithFrame:self.host.bounds];
        _label.numberOfLines = 0;
        _label.font = [UIFont systemFontOfSize:13];
        _label.textColor = [UIColor labelColor];
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.host addSubview:_label];
        _bordered = YES;
    }
    return self;
}

- (NSString *)stringValue { return _label.text ?: @""; }
- (void)setStringValue:(NSString *)v { _label.text = v; }

- (NSFont *)font { return _font; }
- (void)setFont:(NSFont *)f {
    _font = f;
    if (f) _label.font = [f mt_uiFont];
}

- (NSColor *)textColor { return _tfTextColor; }
- (void)setTextColor:(NSColor *)c {
    _tfTextColor = c;
    _label.textColor = c ? [c mt_uiColor] : [UIColor labelColor];
}

- (void)setBackgroundColor:(NSColor *)c {
    [super setBackgroundColor:c];
    _label.backgroundColor = c ? [c mt_uiColor] : [UIColor clearColor];
}

- (BOOL)bordered { return _bordered; }
- (void)setBordered:(BOOL)b { _bordered = b; }

- (BOOL)editable { return _editable; }
- (void)setEditable:(BOOL)e { _editable = e; }

- (BOOL)selectable { return _selectable; }
- (void)setSelectable:(BOOL)s { _selectable = s; }

- (NSInteger)alignment { return (NSInteger)_label.textAlignment; }
- (void)setAlignment:(NSInteger)a { _label.textAlignment = (NSTextAlignment)a; }

@end

#pragma mark - NSControl / NSButton（占位，够用即可）

@interface NSControl : NSView
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@property (nonatomic, assign) NSInteger integerValue;
@end

@implementation NSControl
@end

@interface NSButton : NSControl
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) NSInteger bezelStyle;
- (instancetype)initWithFrame:(NSRect)frameRect;
- (void)setButtonType:(NSInteger)type;
@end

@implementation NSButton {
    UIButton *_button;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _button = [UIButton buttonWithType:UIButtonTypeSystem];
        _button.frame = self.host.bounds;
        _button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.host addSubview:_button];
    }
    return self;
}

- (NSString *)title { return [_button titleForState:UIControlStateNormal] ?: @""; }
- (void)setTitle:(NSString *)t { [_button setTitle:t forState:UIControlStateNormal]; }
- (void)setButtonType:(NSInteger)type { }

@end

#pragma mark - NSImage（占位）

@interface NSImage : NSObject
@property (nonatomic, assign) NSSize size;
+ (NSImage *)imageNamed:(NSString *)name;
@end

@implementation NSImage
+ (NSImage *)imageNamed:(NSString *)name { return nil; }
@end
