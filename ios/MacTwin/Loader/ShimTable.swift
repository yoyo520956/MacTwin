//  ShimTable.swift
//  MacTwin — shim 查找（Swift 侧薄封装）
//
//  真正的 shim 实现在 ShimBridge.c 里（C 更稳，没有 Swift/C 互操作陷阱）。
//  这里只做名字查找 + 状态读取。

import Foundation

enum ShimTable {

    /// 返回 shim 函数指针；不是 shim 就返回 nil
    static func lookup(_ name: String) -> UnsafeMutableRawPointer? {
        // C 侧按名字查；统一去掉可能的领下划线
        let bare = name.hasPrefix("_") ? String(name.dropFirst()) : name
        return bare.withCString { cs in
            if let p = mactwin_shim_lookup(cs) { return p }
            // 再试带下划线的原始名（有些符号确实以 _ 开头）
            return name.withCString { mactwin_shim_lookup($0) }
        }
    }

    /// 目标程序上次运行写下的退出码
    static var lastExitCode: Int32 { mactwin_last_exit_code() }

    /// exit 是否被拦截过
    static var exitWasCalled: Bool { mactwin_exit_was_called() != 0 }

    /// 重置跨运行状态
    static func reset() { mactwin_reset_state() }

    /// 被拦截的调用说明（多行）
    static var notes: String {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = mactwin_notes_copy(&buf, Int32(buf.count))
        guard n > 0 else { return "" }
        return String(cString: buf)
    }
}