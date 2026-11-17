//  RuntimeState.swift
//  MacTwin — 跨模块共享的运行状态
//
//  退出码等关键状态以 C 侧（ShimBridge.c）为准，Swift 这里只做转发和补充。

import Foundation

final class RuntimeState {
    static let shared = RuntimeState()
    private init() {}

    /// 退出码：以 C 侧记录为准（shim exit 会写进去）
    var exitCode: Int32 {
        get { mactwin_last_exit_code() }
        set { mactwin_set_exit_code(newValue) }
    }

    var exitWasCalled: Bool { ShimTable.exitWasCalled }

    /// 附加诊断信息（Swift 侧）
    private let lock = NSLock()
    private var extras: [String] = []
    private var _lastError: String = ""

    var lastError: String {
        get { lock.lock(); defer { lock.unlock() }; return _lastError }
        set { lock.lock(); defer { lock.unlock() }; _lastError = newValue }
    }

    /// 记录一次拦截/异常（同时进 Swift extras 和 C 侧 notes）
    func recordIntercept(_ text: String) {
        lock.lock()
        if extras.count < 32, !extras.contains(text) { extras.append(text) }
        lock.unlock()
    }

    var intercepted: [String] {
        lock.lock(); defer { lock.unlock() }
        return extras
    }

    /// 汇总所有诊断（C 侧 + Swift 侧）
    var diagnostics: String {
        var parts: [String] = []
        let c = ShimTable.notes
        if !c.isEmpty { parts.append(c) }
        let s = intercepted
        if !s.isEmpty { parts.append(s.joined(separator: "\n")) }
        return parts.joined(separator: "\n")
    }

    func reset() {
        mactwin_reset_state()
        lock.lock()
        extras.removeAll()
        _lastError = ""
        lock.unlock()
    }
}