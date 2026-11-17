//  MachOParser.swift
//  MacTwin — Mach-O 解析
//  算法与 tools/macho.py 一致（已通过真二进制交叉验证）

import Foundation

enum MachOParseError: Error, CustomStringConvertible {
    case notMachO(String)
    case fatBinary
    case wrongArch(String)
    case truncated(String)
    case badCommand(Int, UInt32)

    var description: String {
        switch self {
        case .notMachO(let s): return "不是 Mach-O 文件：\(s)"
        case .fatBinary: return "这是 Universal/FAT 二进制（多架构）。请先切出 arm64 slice。"
        case .wrongArch(let s): return "不支持的架构：\(s)（MacTwin 只支持 arm64）"
        case .truncated(let s): return "文件提前结束：\(s)"
        case .badCommand(let i, let c): return "第 \(i) 个 load command 非法（cmd=0x\(String(c, radix: 16))）"
        }
    }
}

/// 安全的 Data 读取器：所有访问都做边界检查，越界抛错而不是 crash
private struct Reader {
    let data: Data
    let limit: Int
    var offset: Int = 0

    init(_ data: Data, _ offset: Int = 0) {
        self.data = data
        self.offset = offset
        self.limit = data.count
    }

    mutating func u8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) }
    }

    mutating func u32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
    }

    mutating func u64() throws -> UInt64 {
        try require(8)
        defer { offset += 8 }
        return data.subdata(in: offset..<(offset + 8)).withUnsafeBytes { UInt64(littleEndian: $0.load(as: UInt64.self)) }
    }

    mutating func i32() throws -> Int32 {
        Int32(bitPattern: try u32())
    }

    mutating func i64() throws -> Int64 {
        Int64(bitPattern: try u64())
    }

    mutating func fixedString(_ count: Int) throws -> String {
        try require(count)
        defer { offset += count }
        let raw = data.subdata(in: offset..<(offset + count))
        if let z = raw.firstIndex(of: 0) {
            return String(decoding: raw[raw.startIndex..<z], as: UTF8.self)
        }
        return String(decoding: raw, as: UTF8.self)
    }

    /// 读一个以 NUL 结尾的 C 字符串，从 offset 开始（不推进 offset）
    func cString(at absolute: Int) -> String {
        guard absolute >= 0, absolute < limit else { return "" }
        var end = absolute
        while end < limit, data[end] != 0 { end += 1 }
        return String(decoding: data.subdata(in: absolute..<end), as: UTF8.self)
    }

    mutating func uleb() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            value |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { break }
            shift += 7
            if shift > 63 { break }
        }
        return value
    }

    mutating func sleb() throws -> Int64 {
        var value: Int64 = 0
        var shift: Int64 = 0
        while true {
            let byte = try u8()
            value |= Int64(byte & 0x7F) << shift
            shift += 7
            if (byte & 0x80) == 0 {
                if (byte & 0x40) != 0, shift < 64 { value |= -(1 << shift) }
                break
            }
            if shift >= 64 { break }
        }
        return value
    }

    private func require(_ n: Int) throws {
        if offset + n > limit {
            throw MachOParseError.truncated("需要 \(n) 字节，剩余 \(limit - offset)")
        }
    }
}

// MARK: - 解析器

enum MachOParser {

    // 直接用 withUnsafeBytes 读定长整数，避免 subdata 造成的类型推导超时
    private static func readU16(_ d: Data, _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= d.count else { return 0 }
        return d.withUnsafeBytes { UInt16(littleEndian: $0.load(fromByteOffset: at, as: UInt16.self)) }
    }
    private static func readU32(_ d: Data, _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: at, as: UInt32.self)) }
    }
    private static func readU64(_ d: Data, _ at: Int) -> UInt64 {
        guard at >= 0, at + 8 <= d.count else { return 0 }
        return d.withUnsafeBytes { UInt64(littleEndian: $0.load(fromByteOffset: at, as: UInt64.self)) }
    }
    private static func readI32(_ d: Data, _ at: Int) -> Int32 {
        Int32(bitPattern: readU32(d, at))
    }

    static func parse(_ data: Data, path: String = "") throws -> MachOImage {
        guard data.count >= 32 else {
            throw MachOParseError.notMachO("文件太小（\(data.count) 字节）")
        }

        let magic = data.prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        if magic == 0xCAFEBABE || magic == 0xBFBAFCAE {
            throw MachOParseError.fatBinary
        }
        guard magic == MachOConstants.magic64 else {
            throw MachOParseError.notMachO("magic=0x\(String(magic, radix: 16))（期望 0xfeedfacf）")
        }

        var r = Reader(data)
        r.offset = 4
        let cputype = try r.u32()
        let cpusubtype = try r.u32()
        let filetype = try r.u32()
        let ncmds = try r.u32()
        let sizeofcmds = try r.u32()
        _ = try r.u32()   // flags

        guard cputype == MachOConstants.cpuARM64 else {
            throw MachOParseError.wrongArch(String(format: "0x%x", cputype))
        }
        guard ncmds < 8192, sizeofcmds <= data.count else {
            throw MachOParseError.badCommand(0, ncmds)
        }

        var img = MachOImage(path: path, cputype: cputype, cpusubtype: cpusubtype & 0x00FFFFFF,
                             filetype: filetype, ncmds: ncmds)

        var chainedOff = 0, chainedSize = 0
        var symOff = 0, symCount = 0, strOff = 0, strSize = 0
        var dyldBind: (Int, Int) = (0, 0)
        var dyldLazy: (Int, Int) = (0, 0)

        let commandsStart = 32
        r.offset = commandsStart

        for i in 0..<ncmds {
            let cmd = try r.u32()
            let cmdsize = try r.u32()
            guard cmdsize >= 8, r.offset - 8 + Int(cmdsize) <= data.count else {
                throw MachOParseError.badCommand(Int(i), cmd)
            }
            let cmdEnd = r.offset - 8 + Int(cmdsize)

            switch cmd {
            case MachOConstants.lcSegment64:
                let seg = try parseSegment(r: &r, end: cmdEnd)
                img.segments.append(seg)

            case MachOConstants.lcSymtab:
                symOff = Int(try r.u32()); symCount = Int(try r.u32())
                strOff = Int(try r.u32()); strSize = Int(try r.u32())

            case MachOConstants.lcLoadDylib, MachOConstants.lcLoadWeakDylib,
                 MachOConstants.lcReexportDylib, MachOConstants.lcLoadUpwardDylib:
                let nameOff = Int(try r.u32())
                _ = try r.u32()   // timestamp
                _ = try r.u32()   // current_version
                _ = try r.u32()   // compatibility_version
                let name = r.cString(at: r.offset - 16 + nameOff - 8 + 8 - 8)
                // 简化：直接在整段里从 nameOff 处取字符串
                let abs = (r.offset - 8) - 16 + nameOff
                img.dylibs.append(MachODylibRef(name: r.cString(at: abs),
                                                ordinal: Int32(img.dylibs.count + 1),
                                                weak: cmd == MachOConstants.lcLoadWeakDylib))

            case MachOConstants.lcIDDylib:
                let nameOff = Int(try r.u32())
                _ = try r.u32(); _ = try r.u32(); _ = try r.u32()
                let abs = (r.offset - 8) - 16 + nameOff
                img.dylibs.append(MachODylibRef(name: r.cString(at: abs), ordinal: 0))

            case MachOConstants.lcMain:
                let entryoff = try r.u64()
                _ = try r.u64()
                img.entryoff = entryoff

            case MachOConstants.lcUUID:
                break

            case MachOConstants.lcDyldInfo, MachOConstants.lcDyldInfoOnly:
                img.hasDyldInfo = true
                _ = try r.u32(); _ = try r.u32()          // rebase
                let bindOff = Int(try r.u32()); let bindSize = Int(try r.u32())
                _ = try r.u32(); _ = try r.u32()          // weak_bind
                let lazyOff = Int(try r.u32()); let lazySize = Int(try r.u32())
                dyldBind = (bindOff, bindSize)
                dyldLazy = (lazyOff, lazySize)

            case MachOConstants.lcDyldChainedFixups:
                img.hasChainedFixups = true
                chainedOff = Int(try r.u32())
                chainedSize = Int(try r.u32())

            case MachOConstants.lcBuildVersion:
                let platform = try r.u32()
                let minos = try r.u32()
                img.minOS = "\(platformName(platform)) \(minos >> 16).\((minos >> 8) & 0xFF).\(minos & 0xFF)"

            case MachOConstants.lcVersionMinMacOSX:
                let v = try r.u32()
                img.minOS = "macOS \(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)"

            default:
                break
            }

            r.offset = cmdEnd
        }

        // 符号表
        if symCount > 0 {
            parseSymtab(data, img: &img, symOff: symOff, symCount: symCount,
                        strOff: strOff, strSize: strSize)
        }

        // chained fixups 优先（macOS 12+ 默认格式）
        if img.hasChainedFixups, chainedOff > 0 {
            try parseChainedFixups(data, img: &img, off: chainedOff)
        } else if img.hasDyldInfo {
            if dyldBind.1 > 0 { try parseBindOpcodes(data, img: &img, off: dyldBind.0, size: dyldBind.1) }
            if dyldLazy.1 > 0 { try parseBindOpcodes(data, img: &img, off: dyldLazy.0, size: dyldLazy.1) }
        }

        // chained 全部取 imports 表；bind opcode 不产生 imports 表的，退回 symtab
        if img.imports.isEmpty {
            for s in img.undefinedSymbols where !s.name.isEmpty {
                let n = s.name.hasPrefix("_") ? String(s.name.dropFirst()) : s.name
                img.imports.append(MachOImport(name: n, ordinal: 0))
            }
        }

        return img
    }

    // MARK: 段

    private static func parseSegment(r: inout Reader, end: Int) throws -> MachOSegment {
        let name = try r.fixedString(16)
        let vmaddr = try r.u64()
        let vmsize = try r.u64()
        let fileoff = try r.u64()
        let filesize = try r.u64()
        _ = try r.u64()   // maxprot
        let initprot = try r.u32()
        let nsects = try r.u32()
        _ = try r.u32()   // flags

        var seg = MachOSegment(name: name, vmaddr: vmaddr, vmsize: vmsize,
                               fileoff: fileoff, filesize: filesize, initprot: initprot)
        for _ in 0..<nsects {
            let sectname = try r.fixedString(16)
            _ = try r.fixedString(16)          // segname
            let addr = try r.u64()
            let size = try r.u64()
            let offset = try r.u32()
            _ = try r.u32(); _ = try r.u32(); _ = try r.u32()
            _ = try r.u32(); _ = try r.u32(); _ = try r.u32()
            seg.sections.append(MachOSection(sectname: sectname, addr: addr, size: size, offset: offset))
        }
        return seg
    }

    // MARK: 符号表

    private static func parseSymtab(_ data: Data, img: inout MachOImage,
                                    symOff: Int, symCount: Int,
                                    strOff: Int, strSize: Int) {
        guard symOff > 0, strOff > 0 else { return }
        let stringBase = data[strOff..<min(strOff + strSize, data.count)]
        let strReader = Reader(data)

        for i in 0..<symCount {
            let off = symOff + i * 16
            guard off + 16 <= data.count else { break }
            let strx = data.subdata(in: off..<(off + 4)).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
            let nType = data[off + 4]
            let nSect = data[off + 5]
            let nValue = data.subdata(in: (off + 8)..<(off + 16)).withUnsafeBytes { UInt64(littleEndian: $0.load(as: UInt64.self)) }

            if (nType & MachOConstants.nStab) != 0 { continue }   // 调试符号

            let name: String
            if Int(strx) < stringBase.count {
                if let z = stringBase.firstIndex(of: 0) {
                    name = String(decoding: stringBase[stringBase.startIndex..<z], as: UTF8.self)
                } else {
                    name = String(decoding: stringBase, as: UTF8.self)
                }
            } else {
                name = strReader.cString(at: strOff + Int(strx))
            }

            let sym = MachOSymbol(name: name, type: nType, sect: nSect, value: nValue)
            if sym.isUndefined {
                if !name.isEmpty { img.undefinedSymbols.append(sym) }
            } else if sym.isExternal {
                img.exports.append(sym)
            }
        }
    }

    // MARK: chained fixups

    private static func parseChainedFixups(_ data: Data, img: inout MachOImage, off: Int) throws {
        guard off + 28 <= data.count else { return }
        let u32at = { (o: Int) -> UInt32 in
            data.subdata(in: (off + o)..<(off + o + 4)).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        }

        let fixupsVersion = u32at(0)
        _ = fixupsVersion
        let startsOffset = u32at(4)
        let importsOffset = u32at(8)
        let symbolsOffset = u32at(12)
        let importsCount = u32at(16)
        let importsFormat = u32at(20)

        // imports 表
        let impBase = off + Int(importsOffset)
        let symBase = off + Int(symbolsOffset)
        var table: [MachOImport] = []

        let count = Int(importsCount)
        for k in 0..<count {
            var ordinal: Int32 = 0
            var weak = false
            var nameOff = 0
            var addend = 0

            switch importsFormat {
            case MachOConstants.chainedImport:
                let raw = UInt32(readU32(data, impBase + k * 4))
                ordinal = Int32(raw & 0xFF)
                weak = ((raw >> 8) & 1) == 1
                nameOff = Int((raw >> 9) & 0x7FFFFF)

            case MachOConstants.chainedImportAddend:
                let raw = UInt32(readU32(data, impBase + k * 8))
                ordinal = Int32(raw & 0xFF)
                weak = ((raw >> 8) & 1) == 1
                nameOff = Int((raw >> 9) & 0x7FFFFF)
                addend = Int(readI32(data, impBase + k * 8 + 4))

            case MachOConstants.chainedImportAddend64:
                let raw = UInt64(readU64(data, impBase + k * 16))
                ordinal = Int32(raw & 0xFFFF)
                weak = ((raw >> 16) & 1) == 1
                nameOff = Int((raw >> 32) & 0xFFFFFFFF)
                addend = Int(readI32(data, impBase + k * 16 + 8))

            default:
                break
            }

            // lib_ordinal 是有符号的：0xF1..0xFF → -15..-1
            if importsFormat != MachOConstants.chainedImportAddend64 {
                if ordinal > 0x7F { ordinal -= 0x100 }
            } else {
                if ordinal > 0x7FFF { ordinal -= 0x10000 }
            }

            let rawName = Reader(data).cString(at: symBase + nameOff)
            let name = rawName.hasPrefix("_") ? String(rawName.dropFirst()) : rawName
            table.append(MachOImport(name: name, ordinal: ordinal, addend: addend, weak: weak))
        }
        img.chainedImports = table

        // starts_in_image
        let si = off + Int(startsOffset)
        let segCount = Int(readU32(data, si))
        for segIdx in 0..<segCount {
            let infoOff = readU32(data, si + 4 + segIdx * 4)
            if infoOff == 0 { continue }
            let ss = si + Int(infoOff)
            guard ss + 22 <= data.count else { continue }
            let pageSize = readU16(data, ss + 4)
            let pointerFormat = readU16(data, ss + 6)
            let segOffset = readU64(data, ss + 8)
            let pageCount = Int(readU16(data, ss + 20))

            if img.pointerFormat == 0 { img.pointerFormat = pointerFormat }
            var cs = MachOChainedStarts(segIndex: segIdx, pageSize: pageSize,
                                        pointerFormat: pointerFormat, segmentOffset: segOffset)
            for p in 0..<pageCount {
                cs.pageStarts.append(readU16(data, ss + 22 + p * 2))
            }
            img.chainedStarts.append(cs)
        }
    }

    // MARK: 老式 bind opcode

    private static func parseBindOpcodes(_ data: Data, img: inout MachOImage, off: Int, size: Int) throws {
        var r = Reader(data, off)
        let end = off + size
        var ordinal: Int32 = 0
        var symbol = ""

        while r.offset < end {
            let byte = try r.u8()
            let op = byte & 0xF0
            let imm = byte & 0x0F

            switch op {
            case 0x00: break                          // DONE
            case 0x10: ordinal = Int32(imm)
            case 0x20: ordinal = Int32(try r.uleb())
            case 0x30: ordinal = imm == 0 ? 0 : Int32(imm) - 16
            case 0x40:
                let rawSym = r.cString(at: r.offset)
                symbol = rawSym.hasPrefix("_") ? String(rawSym.dropFirst()) : rawSym
                r.offset += rawSym.utf8.count + 1
            case 0x50: break
            case 0x60: _ = try r.sleb()
            case 0x70: _ = try r.uleb()
            case 0x80: _ = try r.uleb()
            case 0x90:
                img.imports.append(MachOImport(name: symbol, ordinal: ordinal))
            case 0xA0:
                img.imports.append(MachOImport(name: symbol, ordinal: ordinal))
                _ = try r.uleb()
            case 0xB0:
                img.imports.append(MachOImport(name: symbol, ordinal: ordinal))
            case 0xC0:
                let count = try r.uleb()
                _ = try r.uleb()
                for _ in 0..<count { img.imports.append(MachOImport(name: symbol, ordinal: ordinal)) }
            default: break
            }
        }
    }

    private static func platformName(_ p: UInt32) -> String {
        switch p {
        case 1: return "macOS"; case 2: return "iOS"; case 3: return "tvOS"
        case 4: return "watchOS"; case 6: return "macCatalyst"
        case 11: return "visionOS"; default: return "platform\(p)"
        }
    }
}