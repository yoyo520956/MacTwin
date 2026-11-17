//  JITMemory.swift
//  MacTwin — 可执行内存分配
//
//  iOS 默认不允许「可写 → 可执行」。要跑加载进来的代码页必须拿到 JIT。
//  这里实现多级降级，每一步失败都可诊断，绝不崩：
//    A. MAP_JIT + mprotect(RX)          ← 侧载 + StikJIT/StikDebug 后可用
//    B. 匿名 RW + mprotect(RX)          ← macOS / 模拟器可用
//    C. 纯 RW                            ← 不可执行，只能验证映射逻辑

import Foundation

enum JITError: Error, CustomStringConvertible {
    case mmapFailed(String)
    case mprotectFailed(String, Int32)

    var description: String {
        switch self {
        case .mmapFailed(let s): return "内存映射失败：\(s)"
        case .mprotectFailed(let s, let e): return "设置可执行失败：\(s)（errno=\(e)）"
        }
    }
}

enum JITStrategy: String {
    case mapJIT = "MAP_JIT + mprotect"
    case anonRX = "匿名 + mprotect"
    case readWriteOnly = "仅读写（不可执行）"
}

final class JITMapping {
    let pointer: UnsafeMutableRawPointer
    let size: Int
    let strategy: JITStrategy
    private(set) var isExecutable: Bool

    init(pointer: UnsafeMutableRawPointer, size: Int, strategy: JITStrategy, executable: Bool) {
        self.pointer = pointer
        self.size = size
        self.strategy = strategy
        self.isExecutable = executable
    }

    func deallocate() {
        munmap(pointer, size)
    }
}

enum JITMemory {

    /// MAP_JIT 在 Darwin 上是 0x800；如果当前 SDK 已定义就用系统的
    private static let mapJITFlag: Int32 = 0x800
    private static var pageSize: Int { Int(vm_page_size) }

    /// 当前进程是否可能具备 JIT 能力（仅做能力探测，不保证成功）
    static func probeJIT() -> Bool {
        if let m = try? allocate(size: pageSize, label: "probe") {
            let ok = m.isExecutable
            m.deallocate()
            return ok
        }
        return false
    }

    /// 分配一块内存，尽量让它最终可执行
    static func allocate(size: Int, label: String = "image") throws -> JITMapping {
        let aligned = (size + pageSize - 1) / pageSize * pageSize

        // ── 策略 A：MAP_JIT ──
        let p = mmap(nil, aligned,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANON | mapJITFlag,
                     -1, 0)
        if p != MAP_FAILED, let base = p {
            // 尝试转成可执行
            if mprotect(base, aligned, PROT_READ | PROT_EXEC) == 0 {
                return JITMapping(pointer: base, size: aligned,
                                  strategy: .mapJIT, executable: true)
            }
            // mprotect 失败：留着读写能力先映射（后续会明确报「需要 JIT」）
            return JITMapping(pointer: base, size: aligned,
                              strategy: .readWriteOnly, executable: false)
        }

        // ── 策略 B：普通匿名内存 + mprotect ──
        let p2 = mmap(nil, aligned,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON,
                      -1, 0)
        guard p2 != MAP_FAILED, let base2 = p2 else {
            throw JITError.mmapFailed("mmap 返回 MAP_FAILED（请求 \(aligned) 字节）")
        }
        if mprotect(base2, aligned, PROT_READ | PROT_EXEC) == 0 {
            return JITMapping(pointer: base2, size: aligned,
                              strategy: .anonRX, executable: true)
        }

        // ── 策略 C：只能读写 ──
        return JITMapping(pointer: base2, size: aligned,
                          strategy: .readWriteOnly, executable: false)
    }

    /// 把一段已写好的内存标记为可执行
    static func makeExecutable(_ mapping: JITMapping) -> Bool {
        if mapping.isExecutable { return true }
        let ok = mprotect(mapping.pointer, mapping.size, PROT_READ | PROT_EXEC) == 0
        if ok { mapping.isExecutable = true }
        return ok
    }
}