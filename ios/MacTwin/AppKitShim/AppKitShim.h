//
//  AppKitShim.h
//  MacTwin — AppKit 兼容层（最小可用子集）
//
//  为什么需要：macOS 的 GUI 程序通过 AppKit 创建窗口。iOS 上根本没有 AppKit，
//  所以必须自己实现一层，把它映射到 UIKit。
//
//  为什么能用 ObjC 写：iOS 的 Objective-C runtime 是原生的，
//  objc_msgSend / 类 / category / KVC 全部存在。Mac 程序发过来的消息
//  天然就能接住，不需要任何翻译。
//
//  覆盖策略（按实测缺口增长，不追求完整）：
//    第一层  NSApplication / NSWindow / NSView / NSResponder
//    第二层  NSButton / NSTextField / NSImageView / NSProgressIndicator
//    第三层  NSTableView / NSSplitView / NSMenu（后续）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动一个 Mac 风格窗口（由 shim 的 NSApplicationMain 调用）
/// 返回 0 表示正常结束
int32_t MacTwinRunAppKitMain(int argc, char **argv);

/// 当前是否已经有一个 AppKit 会话在跑
BOOL MacTwinAppKitIsRunning(void);

NS_ASSUME_NONNULL_END