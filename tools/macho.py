#!/usr/bin/env python3
"""
macho.py — arm64 macOS Mach-O 解析器（MacTwin P0 验证工具）

用途：在 iSH 里先验证加载算法，确认段布局、符号表、chained fixups
      解析 100% 正确，再移植到 Swift。

不依赖任何第三方库。
"""
import struct
import sys
import os
from dataclasses import dataclass, field
from typing import List, Optional, Dict, Tuple

# ─────────────────────────── 常量 ───────────────────────────

MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_ARM64_32 = 0x0200000C
CPU_TYPE_X86_64 = 0x01000007

FILETYPE = {1: "OBJECT", 2: "EXECUTE", 3: "FVMLIB", 4: "CORE",
            5: "PRELOAD", 6: "DYLIB", 7: "DYLINKER", 8: "BUNDLE",
            9: "DYLIB_STUB", 10: "DSYM", 11: "KEXT_BUNDLE"}

# load commands
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYSYMTAB = 0x0B
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_MAIN = 0x80000028
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_UUID = 0x1B
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
LC_ENCRYPTION_INFO_64 = 0x2C
LC_CODE_SIGNATURE = 0x1D

# nlist n_type 位
N_STAB = 0xE0
N_PEXT = 0x10
N_TYPE = 0x0E
N_EXT = 0x01
N_UNDF = 0x0
N_ABS = 0x2
N_SECT = 0xE
N_PBUD = 0xC

# chained fixups
DYLD_CHAINED_IMPORT = 1
DYLD_CHAINED_IMPORT_ADDEND = 2
DYLD_CHAINED_IMPORT_ADDEND64 = 3

DYLD_CHAINED_PTR_ARM64E = 1
DYLD_CHAINED_PTR_64 = 2
DYLD_CHAINED_PTR_64_OFFSET = 6
DYLD_CHAINED_PTR_ARM64E_USERLAND = 9
DYLD_CHAINED_PTR_ARM64E_USERLAND24 = 12

PTR_FORMAT_NAME = {
    1: "ARM64E", 2: "64", 3: "32", 4: "32_CACHE", 5: "32_FIRMWARE",
    6: "64_OFFSET", 7: "ARM64E_KERNEL", 8: "64_KERNEL_CACHE",
    9: "ARM64E_USERLAND", 10: "ARM64E_FIRMWARE", 11: "X86_64_KERNEL_CACHE",
    12: "ARM64E_USERLAND24",
}

# bind opcode（老格式）
BIND_OPCODE_DONE = 0x00
BIND_OPCODE_SET_DYLIB_ORDINAL_IMM = 0x10
BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB = 0x20
BIND_OPCODE_SET_DYLIB_SPECIAL_IMM = 0x30
BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM = 0x40
BIND_OPCODE_SET_TYPE_IMM = 0x50
BIND_OPCODE_SET_ADDEND_SLEB = 0x60
BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB = 0x70
BIND_OPCODE_ADD_ADDR_ULEB = 0x80
BIND_OPCODE_DO_BIND = 0x90
BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB = 0xA0
BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED = 0xB0
BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB = 0xC0


class ParseError(Exception):
    pass


def _u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def _u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def _i32(b, o):
    return struct.unpack_from("<i", b, o)[0]


def _cstr(b, o, end=None):
    e = b.find(b"\x00", o) if end is None else min(b.find(b"\x00", o), end)
    if e < 0:
        e = len(b)
    return b[o:e].decode("utf-8", "replace")


def _uleb(b, o):
    val = 0
    shift = 0
    while True:
        byte = b[o]
        o += 1
        val |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            break
        shift += 7
    return val, o


def _sleb(b, o):
    val = 0
    shift = 0
    while True:
        byte = b[o]
        o += 1
        val |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            if byte & 0x40:
                val |= -(1 << shift)
            break
    return val, o


# ─────────────────────────── 数据结构 ───────────────────────────

@dataclass
class Section:
    sectname: str
    segname: str
    addr: int
    size: int
    offset: int
    align: int
    flags: int


@dataclass
class Segment:
    name: str
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int
    maxprot: int
    initprot: int
    sections: List[Section] = field(default_factory=list)

    @property
    def prot_str(self):
        s = ""
        s += "r" if self.initprot & 1 else "-"
        s += "w" if self.initprot & 2 else "-"
        s += "x" if self.initprot & 4 else "-"
        return s


@dataclass
class DylibRef:
    name: str
    ordinal: int          # 1-based
    cmd: int
    weak: bool = False


@dataclass
class Import:
    """一个需要绑定的导入符号"""
    name: str
    ordinal: int          # 库序号
    addend: int = 0
    weak: bool = False
    source: str = ""      # 'chained' | 'bind' | 'symtab'


@dataclass
class SymtabEntry:
    name: str
    n_type: int
    n_sect: int
    n_desc: int
    n_value: int

    @property
    def is_undefined(self):
        return (self.n_type & N_TYPE) in (N_UNDF, N_PBUD)

    @property
    def is_external(self):
        return bool(self.n_type & N_EXT)

    @property
    def kind(self):
        t = self.n_type & N_TYPE
        return {N_UNDF: "UNDF", N_ABS: "ABS", N_SECT: "SECT", N_PBUD: "PBUD"}.get(t, f"0x{t:x}")


@dataclass
class ChainedStarts:
    seg_index: int
    page_size: int
    pointer_format: int
    segment_offset: int
    page_starts: List[int] = field(default_factory=list)


@dataclass
class MachOImage:
    path: str = ""
    magic: int = 0
    cputype: int = 0
    cpusubtype: int = 0
    filetype: int = 0
    ncmds: int = 0
    sizeofcmds: int = 0
    flags: int = 0
    segments: List[Segment] = field(default_factory=list)
    dylibs: List[DylibRef] = field(default_factory=list)
    imports: List[Import] = field(default_factory=list)
    exports: List[SymtabEntry] = field(default_factory=list)
    undefined_syms: List[SymtabEntry] = field(default_factory=list)
    symtab: List[SymtabEntry] = field(default_factory=list)
    chained_starts: List[ChainedStarts] = field(default_factory=list)
    entryoff: Optional[int] = None
    uuid: str = ""
    min_os: str = ""
    has_chained_fixups: bool = False
    has_dyld_info: bool = False
    encrypted: bool = False
    arch_name: str = ""
    pointer_format: int = 0
    chained_imports: list = field(default_factory=list)
    bind_slot_count: int = 0

    # ── 派生信息 ──
    @property
    def filetype_name(self):
        return FILETYPE.get(self.filetype, f"0x{self.filetype:x}")

    @property
    def is_arm64(self):
        return self.cputype == CPU_TYPE_ARM64

    def segment(self, name):
        for s in self.segments:
            if s.name == name:
                return s
        return None


# ─────────────────────────── 解析主流程 ───────────────────────────

def parse(path: str) -> MachOImage:
    with open(path, "rb") as f:
        data = f.read()
    return parse_bytes(data, path)


def parse_bytes(data: bytes, path: str = "") -> MachOImage:
    if len(data) < 32:
        raise ParseError("文件太小，不是 Mach-O")

    magic = _u32(data, 0)
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        raise ParseError(
            "这是 FAT/Universal 二进制（含多个架构）。"
            "MacTwin 需要先从里面切出 arm64 thin slice —— 请先用 tools/thin.py 提取。"
        )
    if magic != MH_MAGIC_64:
        if magic == MH_MAGIC:
            raise ParseError("这是 32 位 Mach-O，MacTwin 只支持 arm64")
        if magic == 0xFEEDFACF or magic == 0xCFFAEDFE:
            pass
        raise ParseError(f"magic 不匹配: 0x{magic:08x}（期望 0x{MH_MAGIC_64:08x}）")

    img = MachOImage(path=path, magic=magic)
    img.cputype = _u32(data, 4)
    img.cpusubtype = _u32(data, 8) & 0x00FFFFFF
    img.filetype = _u32(data, 12)
    img.ncmds = _u32(data, 16)
    img.sizeofcmds = _u32(data, 20)
    img.flags = _u32(data, 24)

    img.arch_name = {
        CPU_TYPE_ARM64: "arm64",
        CPU_TYPE_ARM64_32: "arm64_32",
        CPU_TYPE_X86_64: "x86_64",
    }.get(img.cputype, f"cpu=0x{img.cputype:x}")

    if img.ncmds > 4096 or img.sizeofcmds > len(data):
        raise ParseError(f"load commands 异常: ncmds={img.ncmds} sizeofcmds={img.sizeofcmds}")

    off = 32
    chained_off = chained_size = 0
    symtab_off = nsyms = stroff = strsize = 0
    dyld_info = None
    build_version_minos = None

    for i in range(img.ncmds):
        if off + 8 > len(data):
            raise ParseError(f"第 {i} 个 load command 越界")
        cmd = _u32(data, off)
        cmdsize = _u32(data, off + 4)
        if cmdsize < 8 or off + cmdsize > len(data):
            raise ParseError(f"load command {i} cmdsize 非法: {cmdsize}")

        if cmd == LC_SEGMENT_64:
            img.segments.append(_parse_segment(data, off))
        elif cmd == LC_SYMTAB:
            symtab_off = _u32(data, off + 8)
            nsyms = _u32(data, off + 12)
            stroff = _u32(data, off + 16)
            strsize = _u32(data, off + 20)
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB):
            name_off = _u32(data, off + 8)
            img.dylibs.append(DylibRef(
                name=_cstr(data, off + name_off, off + cmdsize),
                ordinal=len(img.dylibs) + 1,
                cmd=cmd,
                weak=(cmd == LC_LOAD_WEAK_DYLIB),
            ))
        elif cmd == LC_ID_DYLIB:
            name_off = _u32(data, off + 8)
            img.dylibs.append(DylibRef(name=_cstr(data, off + name_off, off + cmdsize),
                                       ordinal=0, cmd=cmd))
        elif cmd == LC_MAIN:
            img.entryoff = _u64(data, off + 8)
        elif cmd == LC_UUID:
            u = data[off + 8:off + 24]
            img.uuid = "-".join([u[0:4].hex(), u[4:6].hex(), u[6:8].hex(),
                                 u[8:10].hex(), u[10:16].hex()]).upper()
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            img.has_dyld_info = True
            dyld_info = {
                "rebase": (_u32(data, off + 8), _u32(data, off + 12)),
                "bind": (_u32(data, off + 16), _u32(data, off + 20)),
                "weak_bind": (_u32(data, off + 24), _u32(data, off + 28)),
                "lazy_bind": (_u32(data, off + 32), _u32(data, off + 36)),
                "export": (_u32(data, off + 40), _u32(data, off + 44)),
            }
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            img.has_chained_fixups = True
            chained_off = _u32(data, off + 8)
            chained_size = _u32(data, off + 12)
        elif cmd == LC_BUILD_VERSION:
            platform = _u32(data, off + 8)
            minos = _u32(data, off + 12)
            build_version_minos = "%d.%d.%d" % (minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF)
            img.min_os = f"{_platform_name(platform)} {build_version_minos}"
        elif cmd == LC_VERSION_MIN_MACOSX:
            v = _u32(data, off + 8)
            img.min_os = "macOS %d.%d.%d" % (v >> 16, (v >> 8) & 0xFF, v & 0xFF)
        elif cmd == LC_ENCRYPTION_INFO_64:
            cryptid = _u32(data, off + 16)
            img.encrypted = cryptid != 0

        off += cmdsize

    # ── 符号表 ──
    if symtab_off and nsyms:
        _parse_symtab(data, img, symtab_off, nsyms, stroff, strsize)

    # ── chained fixups（优先）──
    if img.has_chained_fixups and chained_off:
        _parse_chained_fixups(data, img, chained_off, chained_size)

    # ── 老式 bind opcode ──
    if dyld_info and not img.has_chained_fixups:
        b_off, b_size = dyld_info["bind"]
        if b_size:
            _parse_bind_opcodes(data, img, b_off, b_size, "bind")
        lb_off, lb_size = dyld_info["lazy_bind"]
        if lb_size:
            _parse_bind_opcodes(data, img, lb_off, lb_size, "lazy")

    # 去重导入符号（同名同库只留一条）
    seen = set()
    uniq = []
    for imp in img.imports:
        key = (imp.name, imp.ordinal)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(imp)
    img.imports = uniq

    return img


def _platform_name(p):
    return {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS",
            6: "macCatalyst", 7: "iOSSimulator", 8: "tvOSSimulator",
            9: "watchOSSimulator", 10: "DriverKit", 11: "visionOS",
            12: "visionOSSimulator"}.get(p, f"platform{p}")


def _parse_segment(data, off):
    segname = _cstr(data, off + 8, off + 24)
    seg = Segment(
        name=segname,
        vmaddr=_u64(data, off + 24),
        vmsize=_u64(data, off + 32),
        fileoff=_u64(data, off + 40),
        filesize=_u64(data, off + 48),
        maxprot=_i32(data, off + 56),
        initprot=_i32(data, off + 60),
    )
    nsects = _u32(data, off + 64)
    soff = off + 72
    for _ in range(nsects):
        if soff + 80 > len(data):
            break
        seg.sections.append(Section(
            sectname=_cstr(data, soff, soff + 16),
            segname=_cstr(data, soff + 16, soff + 32),
            addr=_u64(data, soff + 32),
            size=_u64(data, soff + 40),
            offset=_u32(data, soff + 48),
            align=_u32(data, soff + 52),
            flags=_u32(data, soff + 64),
        ))
        soff += 80
    return seg


def _parse_symtab(data, img, symoff, nsyms, stroff, strsize):
    strtab = data[stroff:stroff + strsize]
    for i in range(nsyms):
        off = symoff + i * 16
        if off + 16 > len(data):
            break
        strx = _u32(data, off)
        n_type = data[off + 4]
        n_sect = data[off + 5]
        n_desc = struct.unpack_from("<H", data, off + 6)[0]
        n_value = _u64(data, off + 8)

        if n_type & N_STAB:      # 调试符号，跳过
            continue
        name = _cstr(strtab, strx) if strx < len(strtab) else ""

        entry = SymtabEntry(name=name, n_type=n_type, n_sect=n_sect,
                            n_desc=n_desc, n_value=n_value)
        img.symtab.append(entry)

        if entry.is_undefined:
            if name:
                img.undefined_syms.append(entry)
        elif entry.is_external:
            img.exports.append(entry)


def _parse_chained_fixups(data, img, off, size):
    """解析 LC_DYLD_CHAINED_FIXUPS 指向的 blob"""
    if off + 28 > len(data):
        return
    fixups_version = _u32(data, off)
    starts_offset = _u32(data, off + 4)
    imports_offset = _u32(data, off + 8)
    symbols_offset = _u32(data, off + 12)
    imports_count = _u32(data, off + 16)
    imports_format = _u32(data, off + 20)
    symbols_format = _u32(data, off + 24)

    # ── imports 表 ──
    imp_base = off + imports_offset
    sym_base = off + symbols_offset
    imports = []
    for i in range(imports_count):
        if imports_format == DYLD_CHAINED_IMPORT:
            raw = _u32(data, imp_base + i * 4)
            lib_ord = raw & 0xFF
            weak = (raw >> 8) & 1
            name_off = (raw >> 9) & 0x7FFFFF
            addend = 0
        elif imports_format == DYLD_CHAINED_IMPORT_ADDEND:
            raw = _u32(data, imp_base + i * 8)
            lib_ord = raw & 0xFF
            weak = (raw >> 8) & 1
            name_off = (raw >> 9) & 0x7FFFFF
            addend = _i32(data, imp_base + i * 8 + 4)
        elif imports_format == DYLD_CHAINED_IMPORT_ADDEND64:
            raw = _u64(data, imp_base + i * 16)
            lib_ord = raw & 0xFFFF
            weak = (raw >> 16) & 1
            name_off = (raw >> 32) & 0xFFFFFFFF
            addend = _i32(data, imp_base + i * 16 + 8)
        else:
            break
        # lib_ordinal 是有符号值：0xF1..0xFF 表示 -15..-1
        if imports_format != DYLD_CHAINED_IMPORT_ADDEND64 and lib_ord > 0x7F:
            lib_ord -= 0x100
        elif imports_format == DYLD_CHAINED_IMPORT_ADDEND64 and lib_ord > 0x7FFF:
            lib_ord -= 0x10000
        name = _cstr(data, sym_base + name_off)
        imports.append(Import(name=name, ordinal=lib_ord, addend=addend,
                              weak=bool(weak), source="chained"))

    # ── starts_in_image ──
    si = off + starts_offset
    seg_count = _u32(data, si)
    for seg_idx in range(seg_count):
        seg_info_off = _u32(data, si + 4 + seg_idx * 4)
        if seg_info_off == 0:
            continue
        ss = si + seg_info_off
        _size = _u32(data, ss)
        page_size = struct.unpack_from("<H", data, ss + 4)[0]
        pointer_format = struct.unpack_from("<H", data, ss + 6)[0]
        segment_offset = _u64(data, ss + 8)
        _max_valid = _u32(data, ss + 16)
        page_count = struct.unpack_from("<H", data, ss + 20)[0]

        img.pointer_format = img.pointer_format or pointer_format
        cs = ChainedStarts(seg_index=seg_idx, page_size=page_size,
                           pointer_format=pointer_format,
                           segment_offset=segment_offset)
        for p in range(page_count):
            cs.page_starts.append(struct.unpack_from("<H", data, ss + 22 + p * 2)[0])
        img.chained_starts.append(cs)

        # 逐页走链，收集 bind 项
        _walk_chains(data, img, imports, cs, pointer_format)

    # ── 权威符号来源：imports 表 ──
    # 链式遍历只用来统计 bind 指针数量（供加载器分页用），
    # 符号全集以 imports 表为准 —— 因为 imports 表覆盖所有被引用的符号，
    # 而遍历可能因为多起点页/未知格式而漏项。
    img.chained_imports = imports
    if imports:
        for imp in imports:
            img.imports.append(Import(name=imp.name, ordinal=imp.ordinal,
                                      addend=imp.addend, weak=imp.weak,
                                      source="chained"))

    if not img.imports:
        for e in img.undefined_syms:
            img.imports.append(Import(name=e.name.lstrip("_"), ordinal=0,
                                      source="symtab"))


def _walk_chains(data, img, imports, cs: ChainedStarts, pointer_format):
    """链式指针遍历：确认多少个指针是 bind 型，收集它们的序号"""
    seg = img.segments[cs.seg_index] if cs.seg_index < len(img.segments) else None
    if seg is None:
        return

    for page_idx, start in enumerate(cs.page_starts):
        if start == 0xFFFF:          # DYLD_CHAINED_PTR_START_NONE
            continue
        if start & 0x8000:           # 多起点页（DYLD_CHAINED_PTR_START_MULTI）
            # page_start 指向 additional page starts 表，这里简化为跳过
            continue

        page_off = start
        page_end = cs.page_size if start < 0x4000 else cs.page_size
        guard = 0
        while page_off < page_end and guard < 4096:
            guard += 1
            file_off = seg.fileoff + page_idx * cs.page_size + page_off
            if file_off + 8 > len(data):
                break
            raw = _u64(data, file_off)

            is_bind, ordinal, next_off = _decode_chain_ptr(raw, pointer_format)
            if is_bind:
                img.bind_slot_count += 1
            if next_off <= 0:
                break
            # dyld 规范：next 以 4 字节为单位
            page_off += next_off * 4


def _decode_chain_ptr(raw, fmt):
    """返回 (是否 bind, import 序号或目标, 下一个 offset)"""
    if fmt in (DYLD_CHAINED_PTR_ARM64E, DYLD_CHAINED_PTR_ARM64E_USERLAND,
               DYLD_CHAINED_PTR_ARM64E_USERLAND24):
        auth = (raw >> 63) & 1
        is_bind = (raw >> 62) & 1
        next = (raw >> 51) & 0x7FF
        if is_bind:
            ordinal = raw & 0xFFFF if fmt == DYLD_CHAINED_PTR_ARM64E_USERLAND24 else raw & 0xFFFF
            return True, ordinal, next
        else:
            return False, raw & 0xFFFFFFFF, next

    if fmt in (DYLD_CHAINED_PTR_64, DYLD_CHAINED_PTR_64_OFFSET):
        is_bind = (raw >> 63) & 1
        next = (raw >> 51) & 0xFFF
        if is_bind:
            ordinal = raw & 0xFFFFFF
            return True, ordinal, next
        else:
            return False, raw & 0xFFFFFFFFF, next

    # 未知格式
    return False, 0, 0


def _parse_bind_opcodes(data, img, off, size, kind):
    """老式 bind/lazy_bind opcode 流解析"""
    p = off
    end = off + size
    ordinal = 0
    sym_name = ""
    seg_idx = 0
    seg_off = 0
    addend = 0

    while p < end:
        byte = data[p]
        p += 1
        op = byte & 0xF0
        imm = byte & 0x0F

        if op == BIND_OPCODE_DONE:
            if kind == "bind":
                break
            continue
        elif op == BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
            ordinal = imm
        elif op == BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
            ordinal, p = _uleb(data, p)
        elif op == BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
            ordinal = 0 if imm == 0 else (imm | 0xF0) - 0x100
        elif op == BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
            sym_name = _cstr(data, p)
            p += len(sym_name.encode("utf-8")) + 1
        elif op == BIND_OPCODE_SET_TYPE_IMM:
            pass
        elif op == BIND_OPCODE_SET_ADDEND_SLEB:
            addend, p = _sleb(data, p)
        elif op == BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            seg_idx = imm
            seg_off, p = _uleb(data, p)
        elif op == BIND_OPCODE_ADD_ADDR_ULEB:
            delta, p = _uleb(data, p)
            seg_off += delta
        elif op == BIND_OPCODE_DO_BIND:
            if sym_name:
                img.imports.append(Import(name=sym_name, ordinal=ordinal,
                                          addend=addend, source="bind"))
        elif op == BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
            if sym_name:
                img.imports.append(Import(name=sym_name, ordinal=ordinal,
                                          addend=addend, source="bind"))
            delta, p = _uleb(data, p)
            seg_off += delta
        elif op == BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
            if sym_name:
                img.imports.append(Import(name=sym_name, ordinal=ordinal,
                                          addend=addend, source="bind"))
            seg_off += imm * 8
        elif op == BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
            count, p = _uleb(data, p)
            skip, p = _uleb(data, p)
            for _ in range(min(count, 10000)):
                if sym_name:
                    img.imports.append(Import(name=sym_name, ordinal=ordinal,
                                              addend=addend, source="bind"))
                seg_off += skip
        else:
            break


# ─────────────────────────── 可行性分析 ───────────────────────────

# iOS 上存在的系统库（MacTwin 可以直接直通）
IOS_AVAILABLE = {
    # 核心 libSystem 家族
    "libSystem.B.dylib", "libsystem_kernel.dylib", "libsystem_c.dylib",
    "libsystem_malloc.dylib", "libsystem_pthread.dylib", "libsystem_info.dylib",
    "libsystem_platform.dylib", "libsystem_network.dylib", "libsystem_m.dylib",
    "libc++.1.dylib", "libc++abi.dylib", "libobjc.A.dylib", "libz.1.dylib",
    "libbz2.1.0.dylib", "libiconv.2.dylib", "libxml2.2.dylib", "libsqlite3.dylib",
    "libcompression.dylib", "libarchive.2.dylib", "libcrypto.44.dylib",
    "libssl.48.dylib", "libedit.3.dylib", "libncurses.5.4.dylib",
    "libresolv.9.dylib", "libcharset.1.dylib", "libenergytrace.dylib",
    # 系统 framework（iOS 都有）
    "Foundation", "CoreFoundation", "CoreGraphics", "QuartzCore",
    "CoreText", "CoreImage", "CoreVideo", "CoreMedia", "CoreAudio",
    "AudioToolbox", "AVFoundation", "Metal", "MetalKit", "MetalPerformanceShaders",
    "Security", "SystemConfiguration", "CFNetwork", "ImageIO", "UniformTypeIdentifiers",
    "CoreServices", "CoreSpotlight", "CoreLocation", "CoreData", "CoreML",
    "Network", "JavaScriptCore", "WebKit", "UserNotifications",
    "IOSurface", "CoreAnimation", "OpenGLES", "Accelerate", "Compression",
    "libswiftCore.dylib", "libswiftFoundation.dylib", "libswiftObjectiveC.dylib",
    "libswiftDispatch.dylib", "libswiftCoreGraphics.dylib",
}

# iOS 上不存在的（必须自研 shim 或标记缺失）
IOS_MISSING = {
    "AppKit", "Cocoa", "IOKit", "ScriptingBridge", "Carbon",
    "Quartz", "PDFKit", "Automator", "AppleScriptKit", "DiscRecording",
    "PreferencePanes", "ScreenSaver", "OpenDirectory", "DirectoryService",
    "CoreAudioKit", "AudioUnit", "AudioVideoBridging", "CoreMIDI",
    "CoreWLAN", "ServiceManagement", "LaunchServices", "Spotlight",
    "AddressBook", "CalendarStore", "SyncServices", "ExceptionHandling",
    "InstallerPlugins", "InputMethodKit", "Collaboration", "PubSub",
    "QTKit", "QuickLook", "QuickLookUI", "WebKitLegacy", "DVComponentGlue",
    "ldap", "System", "GSS", "Kerberos",
}


def _lib_basename(path: str) -> str:
    """从 dylib 完整路径里提取用于判断的名字"""
    p = path.split("/")[-1]
    # AppKit.framework/Versions/C/AppKit → AppKit
    if p in ("AppKit", "Foundation", "CoreFoundation", "QuartzCore", "Metal"):
        return p
    # X.framework/Versions/A/X → 向上找 .framework
    parts = path.split("/")
    for part in parts:
        if part.endswith(".framework"):
            return part[: -len(".framework")]
    return p


# 受 Apple macOS umbrella framework 遮蔽、但实际符号在 iOS 上可用的
# 前缀 → iOS 侧真实来源
# 关键：macOS 里很多符号挂在 umbrella（ApplicationServices/Quartz 等）下，
# 但这些符号本身来自 iOS 也有的 CoreGraphics / CoreText / Security。
SYMBOL_PREFIX_AVAILABLE = {
    "CG": "CoreGraphics", "kCG": "CoreGraphics", "CGRect": "CoreGraphics",
    "CGPoint": "CoreGraphics", "CGSize": "CoreGraphics", "CGColor": "CoreGraphics",
    "CGImage": "CoreGraphics", "CGDataProvider": "CoreGraphics",
    "Sec": "Security", "kSec": "Security", "SecItem": "Security",
    "CT": "CoreText", "kCT": "CoreText", "CF": "CoreFoundation",
    "kCF": "CoreFoundation", "AT": "CoreText",
    "IOSurface": "IOSurface", "CGDirect": "CoreGraphics",
    "SecAccess": "Security", "SecKey": "Security", "SecCode": "Security",
    "OBJC_METACLASS": "objc", "OBJC_CLASS": "objc", "_OBJC": "objc",
}

# macOS 专有、iOS 一定没有的符号前缀
SYMBOL_PREFIX_MACOS_ONLY = {
    "PM", "UB", "UAZoom", "AX", "ISI", "FSE", "HIS", "LS", "TIS",
    "SLS", "CGS", "SF", "MDS", "HM", "AXC",
    # IOKit —— iOS 没有 IOKit（只有私有的 IOHID）
    "IO", "IOM", "IOR",
}

# App bundle 内的静态/动态库符号（Chromium/ffmpeg/Node 自带）
SYMBOL_PREFIX_BUNDLED = {
    "av_", "x264_", "vp8_", "vp9_", "opus_", "vpx_", "swr_", "ff_",
    "node_", "uv_", "napi_", "v8_", "V8", "electron", "cc_", "blink",
}

# umbrella framework → 真实归属（用于缺口归因）
UMBRELLA_MAP = {
    "ApplicationServices": None,   # 混合，按符号判定
    "Quartz": None,
    "Carbon": None,
    "CoreGraphics": "CoreGraphics",
    "CoreServices": None,
    "QuickLookUI": None,
    "Automator": None,
    "ScriptingBridge": None,
}


def classify_symbol(name: str, lib_path: str = "") -> str:
    """符号级可用性判定：'system' | 'shim' | 'missing'"""
    if lib_path and classify_dylib(lib_path) in ("system", "bundled", "host"):
        return classify_dylib(lib_path)

    # 1. 去掉下划线前缀（Mach-O 约定）
    n = name[1:] if name.startswith("_") else name

    # 2. macOS 专有优先判死
    for pfx in SYMBOL_PREFIX_MACOS_ONLY:
        if n.startswith(pfx):
            return "missing"

    # 3. AppKit/Foundation 的 NS* —— iOS 没有，MacTwin 必须自研 shim
    if n.startswith("NS"):
        return "shim"

    # 4. App bundle 自带库（通常随 .app 的 Frameworks/ 一起导入）
    for pfx in SYMBOL_PREFIX_BUNDLED:
        if n.startswith(pfx):
            return "bundled"

    # 5. iOS 可用的符号前缀
    for pfx in SYMBOL_PREFIX_AVAILABLE:
        if n.startswith(pfx):
            return "system"

    return "missing"


def classify_dylib(path: str) -> str:
    """返回 'system' | 'shim' | 'missing' | 'bundled' | 'host'"""
    if path.startswith("["):
        return "host"
    if path.startswith("@executable_path") or path.startswith("@loader_path") \
            or path.startswith("@rpath"):
        return "bundled"
    base = _lib_basename(path)
    if base in IOS_MISSING:
        return "shim" if base in ("AppKit", "Cocoa", "LaunchServices",
                                  "QuickLook", "Quartz") else "missing"
    if base in IOS_AVAILABLE:
        return "system"
    if base.startswith("lib") and base.endswith(".dylib"):
        return "system"      # 未知 libX.dylib，大概率能直通
    if path.startswith("/System/Library/Frameworks/"):
        return "missing"     # 没列进名单的 macOS 专有 framework
    return "missing"


def gap_report(img: MachOImage, verbose: bool = False) -> dict:
    """核心可行性分析：这个二进制在 iOS 上能跑吗？"""
    from collections import Counter, defaultdict

    # 按依赖库归组导入符号
    by_lib = defaultdict(list)
    ord_to_lib = {}
    for d in img.dylibs:
        if d.ordinal > 0:
            ord_to_lib[d.ordinal] = d
    for imp in img.imports:
        lib = ord_to_lib.get(imp.ordinal)
        if lib is not None:
            lib_name = lib.name
        elif imp.ordinal == 0:
            # ordinal 0 = 在当前进程全局作用域里查找（宿主导出）
            # 对 .app 主二进制来说，这是被 dlopen 的插件依赖宿主符号
            lib_name = "[host] 主机进程导出"
        elif imp.ordinal == -1:
            lib_name = "[main] 主可执行文件"
        elif imp.ordinal == -2:
            lib_name = "[flat] flat lookup"
        elif imp.ordinal == -3:
            lib_name = "[weak] weak lookup"
        else:
            lib_name = f"(unknown ordinal {imp.ordinal})"
        by_lib[lib_name].append(imp)

    stats = Counter()
    detail = []
    for lib_path, imps in sorted(by_lib.items(), key=lambda kv: -len(kv[1])):
        lib_cls = classify_dylib(lib_path)
        # 对判定为 missing/shim 的库，下沉到符号级再判一次
        # —— macOS umbrella framework 会把大量其实存在于 iOS 的符号
        #    （CG*、Sec*、CF*）也挂在它下面，按库判会严重高估缺口
        if lib_cls in ("missing", "shim"):
            refined = Counter()
            refined_ok = []
            refined_bad = []
            for i in imps:
                sc = classify_symbol(i.name, lib_path)
                refined[sc] += 1
                (refined_ok if sc == "system" else refined_bad).append(i.name)
            # 如果符号级判定把大部分都救回来了，这个库整体算可直通
            if refined.get("system", 0) >= len(imps) * 0.7:
                lib_cls = "system"
            else:
                lib_cls = "missing" if refined.get("missing", 0) >= refined.get("shim", 0) else "shim"
                stats["shim"] += refined.get("shim", 0)
                stats["missing"] += refined.get("missing", 0)
                stats["system"] += refined.get("system", 0)
                detail.append({
                    "lib": lib_path, "kind": lib_cls, "count": len(imps),
                    "symbols": [i.name for i in imps],
                    "refined": dict(refined),
                    "salvageable": len(refined_ok),
                    "unusable": len(refined_bad),
                })
                continue
        stats[lib_cls] += len(imps)
        detail.append({
            "lib": lib_path,
            "kind": lib_cls,
            "count": len(imps),
            "symbols": [i.name for i in imps],
        })

    total = len(img.imports)
    shim = stats.get("shim", 0)
    missing = stats.get("missing", 0)
    system = stats.get("system", 0)
    bundled = stats.get("bundled", 0)
    host = stats.get("host", 0)

    resolvable = system + bundled + host
    gap = shim + missing
    gap_ratio = (gap / total * 100.0) if total else 0.0

    if gap_ratio < 5:
        verdict = "LIKELY_OK —— 缺口很小，预期能跑"
    elif gap_ratio < 15:
        verdict = "NEEDS_SHIM —— 需要补 AppKit 子集"
    elif gap_ratio < 35:
        verdict = "HARD —— 缺口较大，需要大量 shim"
    else:
        verdict = "UNLIKELY —— 缺口过大，短期不支持"

    return {
        "total_imports": total,
        "system": system,
        "bundled": bundled,
        "host": host,
        "shim": shim,
        "missing": missing,
        "gap": gap,
        "gap_ratio": gap_ratio,
        "verdict": verdict,
        "detail": detail,
    }


def print_report(img: MachOImage, verbose: bool = False):
    print("=" * 74)
    print(f"文件      : {img.path}")
    print(f"架构      : {img.arch_name}  (cputype=0x{img.cputype:x} subtype=0x{img.cpusubtype:x})")
    print(f"类型      : {img.filetype_name}")
    print(f"CPU 兼容  : {'✅ 是' if img.is_arm64 else '❌ 否（只支持 arm64）'}")
    print(f"最低系统  : {img.min_os or '(未声明)'}")
    print(f"UUID      : {img.uuid or '-'}")
    print(f"加密      : {'❌ 是（需先解密）' if img.encrypted else '✅ 否'}")
    print(f"Fixups    : {'chained' if img.has_chained_fixups else ('dyld_info' if img.has_dyld_info else 'symtab-only')}")
    if img.pointer_format:
        print(f"指针格式  : {PTR_FORMAT_NAME.get(img.pointer_format, img.pointer_format)}")
    if img.entryoff is not None:
        print(f"入口偏移  : 0x{img.entryoff:x}")
    print()
    print("── 段布局 ──")
    print(f"{'段名':<18}{'vmaddr':>14}{'vmsize':>14}{'fileoff':>12}{'filesize':>12}  权限  节数")
    for s in img.segments:
        print(f"{s.name:<18}0x{s.vmaddr:012x} 0x{s.vmsize:012x} 0x{s.fileoff:010x} 0x{s.filesize:010x}  {s.prot_str}  {len(s.sections)}")
    print()
    print("── 依赖库 ──")
    for d in img.dylibs:
        if d.ordinal == 0:
            print(f"   [id] {d.name}")
        else:
            cls = classify_dylib(d.name)
            mark = {"system": "✅", "bundled": "📦", "shim": "🔧", "missing": "❌"}[cls]
            weak = " (weak)" if d.weak else ""
            print(f"  {mark} #{d.ordinal:<3} {_lib_basename(d.name)}{weak}\n        {d.name}")
    print()
    print("── 符号 ──")
    print(f"  导入符号总数 : {len(img.imports)}")
    print(f"  符号表条目   : {len(img.symtab)}（导出 {len(img.exports)} / 未定义 {len(img.undefined_syms)}）")
    print()

    rep = gap_report(img)
    print("── 可行性评估 ──")
    print(f"  直通 iOS 系统库 : {rep['system']:>5}  ({rep['system']/max(1,rep['total_imports'])*100:.1f}%)")
    print(f"  App 自带 framework: {rep['bundled']:>5}  ({rep['bundled']/max(1,rep['total_imports'])*100:.1f}%)")
    print(f"  宿主进程提供    : {rep['host']:>5}  ({rep['host']/max(1,rep['total_imports'])*100:.1f}%)  ← 插件/dylib 常见")
    print(f"  需自研 shim     : {rep['shim']:>5}")
    print(f"  完全缺失        : {rep['missing']:>5}")
    print(f"  缺口率          : {rep['gap_ratio']:.1f}%")
    print(f"  结论            : {rep['verdict']}")
    print()

    if verbose or rep["gap_ratio"] > 0:
        print("── 缺口明细（按库）──")
        for d in rep["detail"]:
            if d["kind"] in ("shim", "missing", "host"):
                print(f"  [{d['kind']}] {d['lib']}  → {d['count']} 个符号")
                for s in d["symbols"][:12]:
                    print(f"        {s}")
                if len(d["symbols"]) > 12:
                    print(f"        … 还有 {len(d['symbols']) - 12} 个")
        print()


# ─────────────────────────── CLI ───────────────────────────

def main(argv):
    if len(argv) < 2:
        print("用法: macho.py <文件> [--verbose] [--json]")
        print("  分析 macOS arm64 Mach-O，输出符号缺口报告")
        return 2

    path = argv[1]
    verbose = "--verbose" in argv or "-v" in argv
    as_json = "--json" in argv

    if not os.path.exists(path):
        print(f"文件不存在: {path}")
        return 1

    try:
        img = parse(path)
    except ParseError as e:
        print(f"解析失败: {e}")
        return 1
    except Exception as e:
        print(f"解析异常: {type(e).__name__}: {e}")
        return 1

    if as_json:
        import json
        rep = gap_report(img)
        out = {
            "path": img.path,
            "arch": img.arch_name,
            "filetype": img.filetype_name,
            "is_arm64": img.is_arm64,
            "min_os": img.min_os,
            "dylibs": [{"ordinal": d.ordinal, "name": d.name,
                        "kind": classify_dylib(d.name)} for d in img.dylibs],
            "imports_total": len(img.imports),
            "segments": [{"name": s.name, "vmaddr": s.vmaddr, "vmsize": s.vmsize,
                          "fileoff": s.fileoff, "filesize": s.filesize,
                          "prot": s.prot_str} for s in img.segments],
            "gap": rep,
        }
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        print_report(img, verbose)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
