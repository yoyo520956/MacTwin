//  CrashGuard.swift
//  MacTwin — 崩溃守护
//
//  现实：加载的 macOS 二进制跑在我们 App 的地址空间里。如果它段错误
//  （SIGSEGV / SIGBUS），理论上会带走整个进程。
//
//  iOS 上没法用 fork 隔离，所以最好的兜底是：
//    1. 装信号处理器，崩溃前把「谁崩的、在哪崩的」写进 Documents/CrashLog.txt
//    2. 用户下次打开 App 时把日志展示出来，便于诊断
//
//  这不能让崩溃「不发生」，但能保证「崩溃了也留下线索」，且普通使用路径
//  （缺 JIT、缺符号、非 Mach-O）全部走错误回调，不会到这里。

import Foundation

final class CrashGuard {

    static let shared = CrashGuard()
    private init() {}

    var logURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashLog.txt")
        return base
    }

    /// App 启动时调用一次
    func install() {
        signal(SIGSEGV, { _ in CrashGuard.shared.writeCrash(kind: "SIGSEGV"); exit(1) })
        signal(SIGBUS,  { _ in CrashGuard.shared.writeCrash(kind: "SIGBUS");  exit(1) })
        signal(SIGFPE,  { _ in CrashGuard.shared.writeCrash(kind: "SIGFPE");  exit(1) })
        signal(SIGILL,  { _ in CrashGuard.shared.writeCrash(kind: "SIGILL");  exit(1) })
        // SIGABRT 不拦 —— 我们的 shim 已经把它转成线程退出，不该走到这里
    }

    private func writeCrash(kind: String) {
        // 信号处理器里只能调异步安全函数。用 write(2) 直接落盘。
        let date = Date()
        let lines = [
            "\(kind) at \(ISO8601DateFormatter().string(from: date))",
            "exit code: \(mactwin_last_exit_code())",
            "exit intercepted: \(mactwin_exit_was_called() == 1 ? "yes" : "no")",
        ]
        var data = Data()
        for l in lines {
            if let d = l.data(using: .utf8) { data.append(d); data.append(0xA) }
        }
        // 用 write(2) 写（异步信号安全）。open flags 用数值常量避开命名空间坑：
        // O_WRONLY | O_CREAT | O_TRUNC = 0o1 | 0o2 | 0o4
        let oflag: Int32 = 0o1 | 0o2 | 0o4
        let mode: Int32 = 0o644
        let fd = open(logURL.path, oflag, mode)
        if fd >= 0 {
            data.withUnsafeBytes { buf in
                _ = write(fd, buf.baseAddress, buf.count)
            }
            close(fd)
        }
    }

    /// 上次崩溃信息（若有）
    func lastCrash() -> String? {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return nil }
        return try? String(contentsOf: logURL, encoding: .utf8)
    }

    func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }
}

// O_WRONLY 等常量
extension CrashGuard {
    private static let O_WRONLY = 1
    private static let O_CREAT = 0x000002
    private static let O_TRUNC = 0x000004
}