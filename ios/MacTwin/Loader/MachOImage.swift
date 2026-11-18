//  MachOImage.swift
//  MacTwin — Mach-O 数据模型与常量
//
//  从 tools/macho.py（Python 版，已在真二进制上交叉验证）移植而来。
//  常量与字段布局严格对应 Apple 的 mach-o/loader.h。

import Foundation

// MARK: - 常量

enum MachOConstants {
    static let magic64: UInt32 = 0xFEEDFACF

    static let cpuARM64: UInt32 = 0x0100000C
    static let cpuX86_64: UInt32 = 0x01000007

    // load commands
    static let lcSegment64: UInt32 = 0x19
    static let lcSymtab: UInt32 = 0x02
    static let lcDysymtab: UInt32 = 0x0B
    static let lcLoadDylib: UInt32 = 0x0C
    static let lcIDDylib: UInt32 = 0x0D
    static let lcLoadWeakDylib: UInt32 = 0x80000018
    static let lcReexportDylib: UInt32 = 0x8000001F
    static let lcLoadUpwardDylib: UInt32 = 0x80000023
    static let lcMain: UInt32 = 0x80000028
    static let lcDyldInfoOnly: UInt32 = 0x80000022
    static let lcDyldInfo: UInt32 = 0x22
    static let lcDyldChainedFixups: UInt32 = 0x80000034
    static let lcUUID: UInt32 = 0x1B
    static let lcBuildVersion: UInt32 = 0x32
    static let lcVersionMinMacOSX: UInt32 = 0x24

    // chained fixups
    static let chainedImport: UInt32 = 1
    static let chainedImportAddend: UInt32 = 2
    static let chainedImportAddend64: UInt32 = 3

    static let ptr64: UInt16 = 2
    static let ptr64Offset: UInt16 = 6
    static let ptrARM64E: UInt16 = 1
    static let ptrARM64EUserland: UInt16 = 9
    static let ptrARM64EUserland24: UInt16 = 12

    // filetype
    static let mhExecute: UInt32 = 2
    static let mhDylib: UInt32 = 6
    static let mhBundle: UInt32 = 8

    // nlist n_type
    static let nStab: UInt8 = 0xE0
    static let nExt: UInt8 = 0x01
    static let nType: UInt8 = 0x0E
    static let nUndf: UInt8 = 0x00
    static let nAbs: UInt8 = 0x02
    static let nSect: UInt8 = 0x0E

    static let dyldChainedPtrStartNone: UInt16 = 0xFFFF
    static let dyldChainedPtrStartMulti: UInt16 = 0x8000
}

// MARK: - 数据模型

struct MachOSection {
    let sectname: String
    let addr: UInt64
    let size: UInt64
    let offset: UInt32
}

struct MachOSegment {
    let name: String
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
    let initprot: UInt32
    var sections: [MachOSection] = []

    var isExecutable: Bool { (initprot & 0x4) != 0 }
    var isWritable: Bool { (initprot & 0x2) != 0 }
}

struct MachODylibRef {
    let name: String
    let ordinal: Int32      // 1-based；负数表示 MAIN/FLAT/WEAK
    var weak: Bool = false
}

struct MachOImport {
    let name: String
    let ordinal: Int32
    var addend: Int = 0
    var weak: Bool = false
}

struct MachOSymbol {
    let name: String
    let type: UInt8
    let sect: UInt8
    let value: UInt64

    var isUndefined: Bool { (type & MachOConstants.nType) == MachOConstants.nUndf }
    var isExternal: Bool { (type & MachOConstants.nExt) != 0 }
}

struct MachOChainedStarts {
    let segIndex: Int
    let pageSize: UInt16
    let pointerFormat: UInt16
    let segmentOffset: UInt64
    var pageStarts: [UInt16] = []
}

/// 解析结果（不含运行时地址）
struct MachOImage {
    let path: String
    let cputype: UInt32
    let cpusubtype: UInt32
    let filetype: UInt32
    let ncmds: UInt32
    var segments: [MachOSegment] = []
    var dylibs: [MachODylibRef] = []
    var imports: [MachOImport] = []
    var chainedImports: [MachOImport] = []   // chained fixups 的 imports 表（权威符号来源）
    var exports: [MachOSymbol] = []
    var undefinedSymbols: [MachOSymbol] = []
    var chainedStarts: [MachOChainedStarts] = []
    var entryoff: UInt64?
    var pointerFormat: UInt16 = 0
    var hasChainedFixups: Bool = false
    var hasDyldInfo: Bool = false
    var encrypted: Bool = false
    var minOS: String = ""

    var archName: String {
        switch cputype {
        case MachOConstants.cpuARM64: return "arm64"
        case MachOConstants.cpuX86_64: return "x86_64"
        default: return String(format: "0x%x", cputype)
        }
    }

    var isARM64: Bool { cputype == MachOConstants.cpuARM64 }

    /// 图片首选基址（macOS 可执行文件通常是 0x100000000）
    var preferredBase: UInt64 {
        segments.first(where: { $0.filesize > 0 })?.vmaddr ?? 0
    }

    /// 覆盖地址空间总跨度（含 __PAGEZERO 的保留区）
    var totalSpan: UInt64 {
        guard let last = segments.last else { return 0 }
        let hi = last.vmaddr &+ last.vmsize
        guard let first = segments.first else { return hi }
        return hi &- first.vmaddr
    }

    func segment(named: String) -> MachOSegment? {
        segments.first(where: { $0.name == named })
    }
}