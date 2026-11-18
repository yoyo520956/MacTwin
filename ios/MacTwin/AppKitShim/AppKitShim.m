//  AppKitShim.m
//  MacTwin -- minimal AppKit-to-UIKit bridge layer
//
//  Foundation / CoreGraphics / CoreAnimation already exist on iOS.
//  Only AppKit classes need shimming: NSView, NSWindow, NSApplication.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreGraphics/CGPathFunctions.h>

//  Forward declarations
@class NSView, NSWindow;

//  Associated-object keys
static const void *kMTNSViewKey   = &kMTNSViewKey;
static const void *kMTWindowKey   = &kMTWindowKey;

// ----------------------------------------------------------------
#pragma mark - NSResponder (base class)

@interface NSResponder : NSObject
@end
@implementation NSResponder
@end

// ----------------------------------------------------------------
#pragma mark - NSColor

@interface NSColor : NSObject
@property (nonatomic, readonly) CGFloat red, green, blue, alpha;
+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)blackColor;
+ (NSColor *)whiteColor;
+ (NSColor *)clearColor;
+ (NSColor *)windowBackgroundColor;
- (UIColor *)mt_uiColor;
@end

@implementation NSColor {
    CGFloat _r, _g, _b, _a;
}
+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    NSColor *c = [NSColor new];
    c->_r=r; c->_g=g; c->_b=b; c->_a=a;
    return c;
}
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [self colorWithRed:r green:g blue:b alpha:a];
}
+ (NSColor *)blackColor           { return [self colorWithRed:0 green:0 blue:0 alpha:1]; }
+ (NSColor *)whiteColor           { return [self colorWithRed:1 green:1 blue:1 alpha:1]; }
+ (NSColor *)clearColor           { return [self colorWithRed:0 green:0 blue:0 alpha:0]; }
+ (NSColor *)windowBackgroundColor{ return [self colorWithRed:0.93 green:0.93 blue:0.93 alpha:1]; }
- (UIColor *)mt_uiColor {
    return [UIColor colorWithRed:_r green:_g blue:_b alpha:_a];
}
@end

// ----------------------------------------------------------------
#pragma mark - NSView  (UIView-backed)

// The host UIView that draws
@interface MTViewHost : UIView
@property (nonatomic, weak) NSView *nsView;
@end

@interface NSView : NSResponder
@property (nonatomic, strong) MTViewHost *host;
@property (nonatomic, weak) NSView *superview;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) CGRect bounds;
@property (nonatomic, assign) CGFloat alphaValue;
@property (nonatomic, assign) BOOL hidden;
@property (nonatomic, assign) BOOL wantsLayer;
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, readonly) CALayer *layer;

- (instancetype)initWithFrame:(CGRect)fr;
- (instancetype)init;
- (void)addSubview:(NSView *)v;
- (void)removeFromSuperview;
- (void)setNeedsDisplay:(BOOL)flag;
- (void)setNeedsDisplayInRect:(CGRect)r;
- (void)drawRect:(CGRect)r;
- (void)layout;
- (void)setBackgroundColor:(NSColor *)c;
- (NSColor *)backgroundColor;
@end

@implementation MTViewHost
- (void)drawRect:(CGRect)rect {
    NSView *v = self.nsView;
    if (v) [v drawRect:rect];
}
@end

@implementation NSView {
    NSColor *_bg;
    CGFloat _alphaValue;
    BOOL _hidden;
    BOOL _wantsLayer;
}

- (instancetype)initWithFrame:(CGRect)fr {
    self = [super init];
    if (self) {
        _host = [[MTViewHost alloc] initWithFrame:fr];
        _host.nsView = self;
                objc_setAssociatedObject(_host, kMTNSViewKey, self, OBJC_ASSOCIATION_ASSIGN);
        _alphaValue = 1.0;
        _hidden = NO;
        _wantsLayer = NO;
    }
    return self;
}

- (instancetype)init {
    return [self initWithFrame:CGRectZero];
}

- (CGRect)frame { return _host.frame; }
- (void)setFrame:(CGRect)f { _host.frame = f; }
- (CGRect)bounds { return _host.bounds; }
- (void)setBounds:(CGRect)b { _host.bounds = b; }
- (CGFloat)alphaValue { return _alphaValue; }
- (void)setAlphaValue:(CGFloat)a { _alphaValue = a; _host.alpha = a; }
- (BOOL)hidden { return _hidden; }
- (void)setHidden:(BOOL)h { _hidden = h; _host.hidden = h; }
- (BOOL)wantsLayer { return _wantsLayer; }
- (void)setWantsLayer:(BOOL)w { _wantsLayer = w; }
- (NSInteger)tag { return _host.tag; }
- (void)setTag:(NSInteger)t { _host.tag = t; }
- (CALayer *)layer { return _host.layer; }
- (void)setNeedsDisplay:(BOOL)flag { [_host setNeedsDisplay]; }
- (void)setNeedsDisplayInRect:(CGRect)r { [_host setNeedsDisplayInRect:r]; }
- (void)drawRect:(CGRect)r { /* override by subclass */ }
- (void)layout { [_host layoutIfNeeded]; }
- (NSColor *)backgroundColor { return _bg; }
- (void)setBackgroundColor:(NSColor *)c { _bg = c; _host.backgroundColor = c ? [c mt_uiColor] : [UIColor clearColor]; }

- (void)addSubview:(NSView *)v {
    if (v && v.host) {
        [_host addSubview:v.host];
        v.superview = self;
    }
}
- (void)removeFromSuperview {
    [_host removeFromSuperview];
    self.superview = nil;
}
@end

// ----------------------------------------------------------------
#pragma mark - NSWindow  (UIWindow-backed)

@interface NSWindow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSView *contentView;

- (instancetype)initWithContentRect:(CGRect)cr
                          styleMask:(NSUInteger)sm
                            backing:(NSUInteger)bk
                              defer:(BOOL)df;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)setTitle:(NSString *)t;
- (void)setFrame:(CGRect)fr;
- (void)close;
- (NSRect)contentRectForWindowRect:(NSRect)wr;
@end

@implementation NSWindow {
    UIWindow *_uiWindow;
    NSString *_title;
    NSView *_contentView;
}

- (instancetype)initWithContentRect:(CGRect)cr
                          styleMask:(NSUInteger)sm
                            backing:(NSUInteger)bk
                              defer:(BOOL)df {
    self = [super init];
    if (self) {
        CGRect safe = [UIScreen mainScreen].bounds;
        CGRect winFrame = CGRectMake(0, 0, cr.size.width, cr.size.height);
        _uiWindow = [[UIWindow alloc] initWithFrame:winFrame];
        _uiWindow.backgroundColor = [UIColor whiteColor];
    }
    return self;
}

- (void)makeKeyAndOrderFront:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_uiWindow makeKeyAndVisible];
        _uiWindow.hidden = NO;
    });
}

- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)t {
    _title = t;
    objc_setAssociatedObject(_uiWindow, @"mactwin_title", t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSView *)contentView { return _contentView; }
- (void)setContentView:(NSView *)v {
    _contentView = v;
    if (v && v.host) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_uiWindow.rootViewController.view addSubview:v.host];
            v.host.frame = _uiWindow.bounds;
        });
    }
}
- (void)setFrame:(CGRect)f {
    dispatch_async(dispatch_get_main_queue(), ^{ _uiWindow.frame = f; });
}
- (void)close {
    dispatch_async(dispatch_get_main_queue(), ^{
        _uiWindow.hidden = YES;
        for (UIView *v in [_uiWindow.rootViewController.view subviews]) { [v removeFromSuperview]; }
    });
}
- (NSRect)contentRectForWindowRect:(NSRect)wr { return wr; }
@end

// ----------------------------------------------------------------
#pragma mark - NSApplication

@interface NSApplication : NSObject
@property (nonatomic, weak) id delegate;
+ (NSApplication *)sharedApplication;
- (void)run;
- (void)terminate:(id)sender;
- (void)activateIgnoringOtherApps:(BOOL)b;
@end

@implementation NSApplication {
    UIApplication *_hostApp;
    BOOL _running;
}

+ (NSApplication *)sharedApplication {
    static NSApplication *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [NSApplication new]; });
    return inst;
}

- (void)run {
    _running = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(applicationDidFinishLaunching:)])
            [self.delegate applicationDidFinishLaunching:nil];
    });
}

- (void)terminate:(id)sender {
    _running = NO;
    // don't actually kill the app - just stop
}

- (void)activateIgnoringOtherApps:(BOOL)b { /* no-op on iOS */ }
@end

// ----------------------------------------------------------------
#pragma mark - NSApplicationDelegate protocol

@protocol NSApplicationDelegate <NSObject>
@optional
- (void)applicationDidFinishLaunching:(NSNotification *)n;
- (void)applicationWillTerminate:(NSNotification *)n;
@end

// ----------------------------------------------------------------
#pragma mark - NSFont

@interface NSFont : NSObject
@property (nonatomic, readonly) CGFloat pointSize;
+ (NSFont *)systemFontOfSize:(CGFloat)s;
+ (NSFont *)boldSystemFontOfSize:(CGFloat)s;
+ (NSFont *)fontWithName:(NSString *)n size:(CGFloat)s;
- (UIFont *)mt_uiFont;
@end

@implementation NSFont {
    CGFloat _pt;
    BOOL _bold;
}
+ (NSFont *)systemFontOfSize:(CGFloat)s {
    NSFont *f = [NSFont new]; f->_pt = s; f->_bold = NO;
    return f;
}
+ (NSFont *)boldSystemFontOfSize:(CGFloat)s {
    NSFont *f = [NSFont new]; f->_pt = s; f->_bold = YES;
    return f;
}
+ (NSFont *)fontWithName:(NSString *)n size:(CGFloat)s {
    return [self systemFontOfSize:s];
}
- (CGFloat)pointSize { return _pt; }
- (UIFont *)mt_uiFont {
    return _bold ? [UIFont boldSystemFontOfSize:_pt] : [UIFont systemFontOfSize:_pt];
}
@end

// ----------------------------------------------------------------
#pragma mark - NSTextField  (UILabel-backed)

@interface NSTextField : NSView
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic, strong) NSColor *textColor;
@property (nonatomic) BOOL editable;
@property (nonatomic) BOOL selectable;
- (void)setBordered:(BOOL)b;
@end

@implementation NSTextField {
    UILabel *_label;
    NSColor *_textColor;
    NSFont *_font;
    BOOL _bordered;
}

- (instancetype)initWithFrame:(CGRect)fr {
    self = [super initWithFrame:fr];
    if (self) {
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.numberOfLines = 0;
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.host addSubview:_label];
        [self setBackgroundColor:[NSColor clearColor]];
    }
    return self;
}
- (NSString *)stringValue { return _label.text; }
- (void)setStringValue:(NSString *)s { _label.text = s; }
- (NSFont *)font { return _font; }
- (void)setFont:(NSFont *)f {
    _font = f;
    _label.font = f ? [f mt_uiFont] : [UIFont systemFontOfSize:14];
}
- (NSColor *)textColor { return _textColor; }
- (void)setTextColor:(NSColor *)c {
    _textColor = c;
    _label.textColor = c ? [c mt_uiColor] : [UIColor blackColor];
}
- (void)setBordered:(BOOL)b { _bordered = b; }
- (void)layout {
    [super layout];
    _label.frame = self.host.bounds;
}
@end

// ----------------------------------------------------------------
#pragma mark - NSButton  (UIButton-backed)

@interface NSButton : NSView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
- (void)setBezelStyle:(NSUInteger)s;
- (void)setTarget:(id)t action:(SEL)a;
@end

@implementation NSButton {
    UIButton *_btn;
    NSString *_title;
}
- (instancetype)initWithFrame:(CGRect)fr {
    self = [super initWithFrame:fr];
    if (self) {
        _btn = [[UIButton alloc] initWithFrame:CGRectZero];
        _btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.host addSubview:_btn];
    }
    return self;
}
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)t { _title = t; [_btn setTitle:t forState:UIControlStateNormal]; }
- (void)setBezelStyle:(NSUInteger)s { /* no-op */ }
- (void)setTarget:(id)t action:(SEL)a {
    _target = t;
    _action = a;
    [_btn addTarget:t action:a forControlEvents:UIControlEventTouchUpInside];
}
- (void)layout {
    [super layout];
    _btn.frame = self.host.bounds;
}
@end

// ----------------------------------------------------------------
#pragma mark - NSImage

@interface NSImage : NSObject
+ (NSImage *)imageNamed:(NSString *)n;
- (void)mt_drawInRect:(CGRect)r;
@end

@implementation NSImage
+ (NSImage *)imageNamed:(NSString *)n {
    return [NSImage new];
}
- (void)mt_drawInRect:(CGRect)r { /* placeholder */ }
@end

// ----------------------------------------------------------------
#pragma mark - NSRectFill helpers

void NSRectFill(CGRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) CGContextFillRect(ctx, rect);
}
void NSRectFrame(CGRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) CGContextStrokeRect(ctx, rect);
}
void NSFrameRect(CGRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) CGContextStrokeRect(ctx, rect);
}
CGRect NSMakeRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return CGRectMake(x, y, w, h);
}
CGPoint NSMakePoint(CGFloat x, CGFloat y) { return CGPointMake(x, y); }
CGSize  NSMakeSize(CGFloat w, CGFloat h)  { return CGSizeMake(w, h); }

// ----------------------------------------------------------------
#pragma mark - NSApplicationMain

int NSApplicationMain(int argc, char *argv[]) {
    NSApplication *app = [NSApplication sharedApplication];
    [app run];
    return 0;
}
