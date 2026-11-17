//  SymbolBinder.swift
//  MacTwin — 符号绑定（"实时转译"的核心）
//
//  不做指令翻译。加载时把每个导入符号的地址直接填进它的调用点：
//    ① MacTwin shim（exit/fork/AppKit）—— 必须最先，否则会命中被 iOS 同名的 exit
//    ② iOS 系统 Darwin 符号 —— dlsym(RTLD_DEFAULT, name)
//    ③ 已加载镜像的导出符号
//    ④ 都没有 → 记录缺口 + 返回安全 stub（绝不崩）
//
//  运行期开销 = 一次间接跳转，接近原生。

import Foundation

enum BindMode {
    case lenient      // 缺口返回 stub 并记录（默认）
    case strict       // 缺口直接判定失败（自检用）
}

struct BindReport {
    var direct = 0
    var shimmed = 0
    var fromImage = 0
    var missing: [String] = []
    var total: Int { direct + shimmed + fromImage + missing.count }
    var gapRatio: Double {
        total == 0 ? 0 : Double(missing.count) / Double(total) * 100.0
    }
}

final class SymbolBinder {
    private var imageExports: [String: UnsafeMutableRawPointer] = [:]
    private(set) var report = BindReport()
    var mode: BindMode = .lenient

    /// RTLD_DEFAULT = (void *)-2
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    // MARK: 注册镜像导出

    /// 把已映射镜像的导出符号登记进来
    /// - base: 镜像实际映射基址
    /// - preferredBase: 镜像的首选基址（vmaddr）
    func register(exports: [MachOSymbol], base: UnsafeMutableRawPointer, preferredBase: UInt64) {
        for s in exports where !s.name.isEmpty {
            // 只有定义在段内的符号才有意义（n_value 是 vmaddr）
            guard s.value >= preferredBase else { continue }
            let delta = Int(s.value &- preferredBase)
            let addr = (base + delta)
            imageExports[s.name] = addr
            // 同时登记去掉下划线的名字，方便按「公开名」查找
            if s.name.hasPrefix("_") {
                imageExports[String(s.name.dropFirst())] = addr
            }
        }
    }

    /// 按名字取镜像内导出（用于找 main）
    func imageSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        imageExports[name] ?? imageExports["_" + name]
    }

    // MARK: 解析

    /// name 应为「不带下划线」的公开名（如 malloc）
    func resolve(_ name: String) -> UnsafeMutableRawPointer? {
        // ① MacTwin shim —— 最先查
        if let shim = ShimTable.lookup(name) {
            report.shimmed += 1
            return shim
        }

        // ② iOS 系统符号直通
        if let rtld = SymbolBinder.rtldDefault, let sym = dlsym(rtld, name) {
            report.direct += 1
            return sym
        }

        // ③ 已加载镜像导出
        if let p = imageExports[name] ?? imageExports["_" + name] {
            report.fromImage += 1
            return p
        }

        // ④ 缺口
        if !report.missing.contains(name) { report.missing.append(name) }
        if mode == .strict { return nil }
        // 宽松模式：给一个一定不会野指针的 stub（指向 shim_abort）
        if let stub = ShimTable.lookup("abort") { return stub }
        return nil
    }

    /// 生成人类可读的绑定报告
    func reportText() -> String {
        var lines: [String] = []
        lines.append("符号绑定：共 \(report.total) 个")
        lines.append("  ✅ iOS 直通     \(report.direct)")
        lines.append("  🪄 MacTwin shim \(report.shimmed)")
        lines.append("  📦 镜像内导出   \(report.fromImage)")
        lines.append("  ❌ 缺口         \(report.missing.count)")
        lines.append(String(format: "  缺口率         %.1f%%", report.gapRatio))
        if !report.missing.isEmpty {
            lines.append("")
            lines.append("缺口符号（最多列 30 个）：")
            for n in report.missing.prefix(30) {
                lines.append("  \(n)")
            }
            if report.missing.count > 30 {
                lines.append("  …还有 \(report.missing.count - 30) 个")
            }
        }
        return lines.joined(separator: "\n")
    }
}