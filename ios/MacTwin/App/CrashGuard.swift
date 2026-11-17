//  CrashGuard.swift
//  MacTwin — 崩溃守护（实际逻辑在 ShimBridge.c，异步信号安全）

import Foundation

final class CrashGuard {
    static let shared = CrashGuard()
    private init() {}

    var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashLog.txt")
    }

    /// App 启动时调用
    func install() {
        logURL.path.withCString { mactwin_install_crash_guard($0) }
    }

    /// 上次崩溃信息（若有）
    func lastCrash() -> String? {
        var buf = [CChar](repeating: 0, count: 512)
        let n = mactwin_read_crash(&buf, buf.count)
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    func clear() { mactwin_clear_crash() }
}
