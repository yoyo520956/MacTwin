//  Loader.swift
//  MacTwin — Mach-O 加载器
//
//  流程：读文件 → 解析 → 分配可执行内存 → 拷贝段 → 应用 fixups
//        → 绑定符号 → 找入口 → 返回可调用地址
//
//  全程任何一步失败都抛 MachOLoadError，由调用方展示，绝不 SIGABRT。

import Foundation

enum MachOLoadError: Error, CustomStringConvertible {
    case readFailed(String)
    case parse(String)
    case tooLarge(UInt64)
    case jitRequired
    case noEntryPoint
    case bindFailed(String)

    var description: String {
        switch self {
        case .readFailed(let s): return "读取文件失败：\(s)"
        case .parse(let s): return "解析失败：\(s)"
        case .tooLarge(let n): return String(format: "镜像地址空间过大（%.1f MB），已拒绝", Double(n) / 1048576.0)
        case .jitRequired: return "此设备当前没有 JIT 权限，无法执行加载的代码页。请先用 StikJIT / StikDebug 为 MacTwin 开启 JIT。"
        case .noEntryPoint: return "找不到入口点（没有 main 符号，也没有 LC_MAIN）"
        case .bindFailed(let s): return "符号绑定失败：\(s)"
        }
    }
}

/// 加载完成的结果
final class LoadedImage {
    let image: MachOImage
    let mapping: JITMapping
    let base: UnsafeMutableRawPointer
    let preferredBase: UInt64
    let binder: SymbolBinder

    /// 可调用的入口（main）或 nil
    let entry: UnsafeMutableRawPointer?
    let entryName: String

    init(image: MachOImage, mapping: JITMapping, preferredBase: UInt64,
         binder: SymbolBinder, entry: UnsafeMutableRawPointer?, entryName: String) {
        self.image = image
        self.mapping = mapping
        self.base = mapping.pointer
        self.preferredBase = preferredBase
        self.binder = binder
        self.entry = entry
        self.entryName = entryName
    }

    func unload() {
        mapping.deallocate()
    }

    /// 运行期地址 ↔ vmaddr 换算
    func runtimeAddress(vmaddr: UInt64) -> UnsafeMutableRawPointer {
        base + Int(bitPattern: UInt(vmaddr &- preferredBase))
    }
}

final class Loader {

    /// 加载上限：地址空间跨度超过这个值就拒绝（防 __PAGEZERO 之类误算）
    private let maxSpan: UInt64 = 512 * 1024 * 1024

    func load(data: Data, path: String) throws -> LoadedImage {
        // ① 解析
        let img: MachOImage
        do {
            img = try MachOParser.parse(data, path: path)
        } catch let e as MachOParseError {
            throw MachOLoadError.parse(e.description)
        } catch {
            throw MachOLoadError.parse("\(error)")
        }

        let preferredBase = img.preferredBase
        var span = img.totalSpan
        // __PAGEZERO 会让 span 巨大，但它不占文件内容 → 从首个有内容的段算起
        if span > maxSpan {
            let low = preferredBase
            let high = img.segments.map { $0.vmaddr &+ $0.vmsize }.max() ?? 0
            span = high &- low
        }
        guard span > 0, span <= maxSpan else {
            throw MachOLoadError.tooLarge(span)
        }

        // ② 分配可执行内存
        let mapping: JITMapping
        do {
            mapping = try JITMemory.allocate(size: Int(span))
        } catch let e as JITError {
            throw MachOLoadError.parse(e.description)
        }

        // ③ 拷贝各段内容
        let base = mapping.pointer
        for seg in img.segments where seg.filesize > 0 {
            let dst = base.advanced(by: Int(seg.vmaddr &- preferredBase))
            let start = Int(seg.fileoff)
            let len = Int(seg.filesize)
            guard start >= 0, len >= 0, start + len <= data.count else { continue }
            data.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(dst, src.advanced(by: start), len)
            }
        }

        // ④ 符号绑定器
        let binder = SymbolBinder()
        binder.register(exports: img.exports, base: base, preferredBase: preferredBase)

        // ⑤ 应用 fixups
        try applyChainedFixups(img: img, base: base, preferredBase: preferredBase, binder: binder)

        // ⑥ 让代码段可执行
        _ = JITMemory.makeExecutable(mapping)

        // ⑦ 找入口
        var entry: UnsafeMutableRawPointer?
        var entryName = ""

        if let main = binder.imageSymbol("main") {
            entry = main
            entryName = "main"
        } else if let main = binder.imageSymbol("_main") {
            entry = main
            entryName = "_main"
        } else if let off = img.entryoff {
            entry = base + Int(off)
            entryName = String(format: "LC_MAIN+0x%llx", off)
        }

        return LoadedImage(image: img, mapping: mapping, preferredBase: preferredBase,
                           binder: binder, entry: entry, entryName: entryName)
    }

    // MARK: - fixups

    private func applyChainedFixups(img: MachOImage, base: UnsafeMutableRawPointer,
                                    preferredBase: UInt64, binder: SymbolBinder) throws {
        guard img.hasChainedFixups, !img.chainedStarts.isEmpty else { return }
        let imports = img.chainedImports

        for cs in img.chainedStarts {
            guard cs.segIndex < img.segments.count else { continue }
            let seg = img.segments[cs.segIndex]
            let segBase = base.advanced(by: Int(seg.vmaddr &- preferredBase))

            for (pageIdx, start) in cs.pageStarts.enumerated() {
                if start == MachOConstants.dyldChainedPtrStartNone { continue }
                if (start & MachOConstants.dyldChainedPtrStartMulti) != 0 {
                    // 多起点页：结构更复杂，先跳过并记录
                    RuntimeState.shared.recordIntercept("多起点链页（跳过 seg\(cs.segIndex) page\(pageIdx)）")
                    continue
                }

                var offset = Int(start)
                var guardCount = 0
                let pageLimit = Int(cs.pageSize)

                while offset < pageLimit, guardCount < 8192 {
                    guardCount += 1
                    let slot = segBase.advanced(by: pageIdx * pageLimit + offset)
                    let raw = slot.load(as: UInt64.self)
                    let (value, nextUnits) = decode(raw, format: cs.pointerFormat,
                                                    base: base, preferredBase: preferredBase,
                                                    imports: imports, binder: binder)
                    slot.storeBytes(of: value, as: UInt64.self)
                    if nextUnits == 0 { break }
                    offset += Int(nextUnits) * 4
                }
            }
        }

        if binder.mode == .strict, !binder.report.missing.isEmpty {
            throw MachOLoadError.bindFailed("缺口 \(binder.report.missing.count) 个")
        }
    }

    /// 解码一个链式指针，返回 (修正后的值, next 单位数)
    private func decode(_ raw: UInt64, format: UInt16,
                        base: UnsafeMutableRawPointer, preferredBase: UInt64,
                        imports: [MachOImport],
                        binder: SymbolBinder) -> (UInt64, UInt64) {
        let baseAddr = UInt64(UInt(bitPattern: base))

        switch format {
        case MachOConstants.ptr64, MachOConstants.ptr64Offset:
            let isBind = (raw >> 63) & 1
            let next = (raw >> 51) & 0xFFF

            if isBind == 1 {
                let ordinal = Int(raw & 0xFFFFFF)
                let addend = Int((raw >> 24) & 0xFF)
                guard ordinal < imports.count else { return (0, next) }
                let imp = imports[ordinal]
                guard let sym = binder.resolve(imp.name) else { return (0, next) }
                let symAddr = UInt64(UInt(bitPattern: sym))
                let delta = Int64(addend + imp.addend)
                return (symAddr &+ UInt64(bitPattern: delta), next)
            } else {
                let target = raw & 0xFFFFFFFFFF          // 36 位
                if format == MachOConstants.ptr64Offset {
                    // target 是相对镜像基址的偏移
                    return (baseAddr &+ target, next)
                } else {
                    // 绝对 vmaddr
                    return (baseAddr &+ (target &- preferredBase), next)
                }
            }

        case MachOConstants.ptrARM64E, MachOConstants.ptrARM64EUserland,
             MachOConstants.ptrARM64EUserland24:
            let isBind = (raw >> 62) & 1
            let next = (raw >> 51) & 0x7FF
            if isBind == 1 {
                let ordinal = Int(raw & 0xFFFF)
                guard ordinal < imports.count else { return (0, next) }
                let imp = imports[ordinal]
                guard let sym = binder.resolve(imp.name) else { return (0, next) }
                return (UInt64(UInt(bitPattern: sym)), next)
            } else {
                let target = raw & 0xFFFFFFFF
                return (baseAddr &+ target, next)
            }

        default:
            return (raw, 0)
        }
    }
}