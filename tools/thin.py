#!/usr/bin/env python3
"""
thin.py — 从 FAT/Universal Mach-O 里提取单个架构切片

macOS 上很多二进制是 universal2（x86_64 + arm64 打包在一起）。
MacTwin 只能加载 arm64，所以需要先把 arm64 slice 切出来。

用法:
    thin.py <输入文件> [--list]              列出所有架构
    thin.py <输入文件> -o <输出> --arch arm64  提取 arm64
"""
import struct
import sys
import os

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

CPU_NAMES = {
    0x0100000C: "arm64",
    0x01000007: "x86_64",
    0x00000007: "i386",
    0x0200000C: "arm64_32",
    0x0000000C: "arm",
    0x01000012: "ppc64",
}


def read_arches(data):
    if len(data) < 8:
        return []
    magic = struct.unpack_from(">I", data, 0)[0]   # FAT 头是大端
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return []
    n = struct.unpack_from(">I", data, 4)[0]
    if n > 32:
        return []
    arches = []
    if magic == FAT_MAGIC:
        off = 8
        for i in range(n):
            if off + 20 > len(data):
                break
            cputype, cpusub, offset, size, align = struct.unpack_from(">IiIII", data, off)
            arches.append(dict(index=i, cputype=cputype, cpusubtype=cpusub,
                               offset=offset, size=size, align=align))
            off += 20
    else:
        off = 8
        for i in range(n):
            if off + 32 > len(data):
                break
            cputype, cpusub, offset, size, align, _res = struct.unpack_from(">IiQQQI", data, off)
            arches.append(dict(index=i, cputype=cputype, cpusubtype=cpusub,
                               offset=offset, size=size, align=align))
            off += 32
    return arches


def is_fat(data):
    if len(data) < 4:
        return False
    return struct.unpack_from(">I", data, 0)[0] in (FAT_MAGIC, FAT_MAGIC_64)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    src = argv[1]
    if not os.path.exists(src):
        print(f"文件不存在: {src}")
        return 1
    with open(src, "rb") as f:
        data = f.read()

    if not is_fat(data):
        print(f"不是 FAT 二进制（可能是单架构 thin 文件）")
        if "--list" in argv:
            return 0
        return 1

    arches = read_arches(data)
    print(f"{src}")
    print(f"  FAT，共 {len(arches)} 个架构：")
    for a in arches:
        name = CPU_NAMES.get(a["cputype"], f"0x{a['cputype']:x}")
        print(f"   [{a['index']}] {name:<8} cpusubtype=0x{a['cpusubtype']:x} "
              f"offset={a['offset']} size={a['size']} align=2^{a['align']}")

    if "--list" in argv or "-l" in argv:
        return 0

    want = "arm64"
    if "--arch" in argv:
        want = argv[argv.index("--arch") + 1]

    pick = None
    for a in arches:
        if CPU_NAMES.get(a["cputype"]) == want:
            pick = a
            break
    if pick is None:
        print(f"❌ 没有找到 {want} 架构")
        return 1

    out = argv[argv.index("-o") + 1] if "-o" in argv else src + "." + want
    blob = data[pick["offset"]: pick["offset"] + pick["size"]]
    with open(out, "wb") as f:
        f.write(blob)
    os.chmod(out, 0o755)
    print(f"✅ 已提取 {want} → {out} ({len(blob)} 字节)")

    # 验证切片头的 magic
    if len(blob) >= 4:
        m = struct.unpack_from("<I", blob, 0)[0]
        print(f"   切片 magic: 0x{m:08x} " + ("(MH_MAGIC_64 ✅)" if m == 0xFEEDFACF else "(⚠️ 不是 64 位 Mach-O)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
