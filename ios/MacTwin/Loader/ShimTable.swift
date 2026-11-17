//  ShimTable.swift
//  MacTwin — 自研符号表（防崩安全网）
//
//  这一层是「不闪退」的根本保障。macOS CLI 会调用 exit()/abort()，
//  如果不拦截，会直接终结我们的 App。fork/exec iOS 禁止，不拦就崩。
//
//  所有 shim 都是 @_cdecl 的 C 函数入口，unsafeBitCast 成指针填进绑定点。

import Foundation

// ─────────────────────────────────────────────────────────────
// 线程生命周期管理
//
// 目标二进制跑在独立线程上。shimExit 用 pthread_exit 终止
// *这一条线程*，而不是进程 —— 这是「不会闪退」的关键。
// ─────────────────────────────────────────────────────────────

final class RuntimeState {
    static let shared = RuntimeState()
    private init() {}

    private let lock = NSLock()
    private var _exitCode: Int32 = 0
    private var _lastError: String = ""

    var exitCode: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return _exitCode }
        set { lock.lock(); defer { lock.unlock() }; _exitCode = newValue }
    }

    var lastError: String {
        get { lock.lock(); defer { lock.unlock() }; return _lastError }
        set { lock.lock(); defer { lock.unlock() }; _lastError = newValue }
    }

    /// 记录一次「被拦截的调用」，用于 UI 显示
    private(set) var intercepted: [String] = []
    func recordIntercept(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if intercepted.count < 64, !intercepted.contains(name) {
            intercepted.append(name)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// C 可调用 shim
// ─────────────────────────────────────────────────────────────

/// 拦截 exit/_exit：记码并只终止当前线程，绝不杀进程
@_cdecl("mactwin_shim_exit")
func mactwin_shim_exit(_ code: Int32) -> Never {
    RuntimeState.shared.exitCode = code
    RuntimeState.shared.recordIntercept("exit(\(code))")
    pthread_exit(nil)
    // pthread_exit 不返回；这里仅为满足 Never 语义
    fatalError("unreachable")
}

/// 拦截 abort：等价于 exit(134)
@_cdecl("mactwin_shim_abort")
func mactwin_shim_abort() -> Never {
    RuntimeState.shared.recordIntercept("abort")
    mactwin_shim_exit(134)
}

/// 拦截 fork/vfork：iOS 沙箱禁止创建进程，返回失败而不崩
@_cdecl("mactwin_shim_fork")
func mactwin_shim_fork() -> Int32 {
    RuntimeState.shared.recordIntercept("fork → ENOSYS")
    errno = 78      // ENOSYS
    return -1
}

/// 拦截 execve 家族
@_cdecl("mactwin_shim_execve")
func mactwin_shim_execve(_ path: UnsafePointer<CChar>?,
                         _ argv: UnsafePointer<UnsafePointer<CChar>?>?,
                         _ envp: UnsafePointer<UnsafePointer<CChar>?>?) -> Int32 {
    RuntimeState.shared.recordIntercept("execve → ENOSYS")
    errno = 78
    return -1
}

/// 拦截 system()
@_cdecl("mactwin_shim_system")
func mactwin_shim_system(_ command: UnsafePointer<CChar>?) -> Int32 {
    RuntimeState.shared.recordIntercept("system → ENOSYS")
    errno = 78
    return -1
}

/// 拦截 dyld_stub_binder（我们已做急切绑定，不该走到这里；走到说明有漏绑）
@_cdecl("mactwin_shim_stub_binder")
func mactwin_shim_stub_binder() -> UnsafeMutableRawPointer? {
    RuntimeState.shared.recordIntercept("dyld_stub_binder（漏绑）")
    RuntimeState.shared.lastError = "有符号走了 lazy bind 但未急切绑定"
    return nil
}

// ─────────────────────────────────────────────────────────────
// 查找表
// ─────────────────────────────────────────────────────────────

enum ShimTable {
    /// 返回 shim 的函数指针；不是 shim 的返回 nil
    static func lookup(_ name: String) -> UnsafeMutableRawPointer? {
        switch name {
        case "exit":
            return unsafeBitCast(mactwin_shim_exit,
                                 to: UnsafeMutableRawPointer.self)
        case "_exit":
            return unsafeBitCast(mactwin_shim_exit,
                                 to: UnsafeMutableRawPointer.self)
        case "abort":
            return unsafeBitCast(mactwin_shim_abort,
                                 to: UnsafeMutableRawPointer.self)
        case "__assert_rtn", "assert_rtn":
            return unsafeBitCast(mactwin_shim_abort,
                                 to: UnsafeMutableRawPointer.self)
        case "fork":
            return unsafeBitCast(mactwin_shim_fork,
                                 to: UnsafeMutableRawPointer.self)
        case "vfork":
            return unsafeBitCast(mactwin_shim_fork,
                                 to: UnsafeMutableRawPointer.self)
        case "execve":
            return unsafeBitCast(mactwin_shim_execve,
                                 to: UnsafeMutableRawPointer.self)
        case "system":
            return unsafeBitCast(mactwin_shim_system,
                                 to: UnsafeMutableRawPointer.self)
        case "dyld_stub_binder":
            return unsafeBitCast(mactwin_shim_stub_binder,
                                 to: UnsafeMutableRawPointer.self)

        // ── AppKit / GUI shim（P5 起实现，先占位）──
        case "NSApplicationMain":
            return unsafeBitCast(mactwin_shim_stub_binder,
                                 to: UnsafeMutableRawPointer.self)

        default:
            return nil
        }
    }

    /// 记录过的拦截统计
    static func summary() -> (intercepted: [String], exitCode: Int32) {
        (RuntimeState.shared.intercepted, RuntimeState.shared.exitCode)
    }
}