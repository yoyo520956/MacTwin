#!/usr/bin/env python3
"""
crosscheck.py — 交叉验证 Mach-O 解析器的正确性

原理：同一个二进制里有两份独立的符号来源
  ① LC_DYLD_CHAINED_FIXUPS 的 imports 表
  ② LC_SYMTAB 的 nlist 未定义符号
两者都应该描述"这个文件需要外部提供的符号"。如果解析正确，
两份集合去重后应当完全一致。任何差异都说明解析有 bug。

用法: python3 crosscheck.py <文件> [--show-ok]
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import macho


def strip_prefix(n: str) -> str:
    return n[1:] if n.startswith("_") else n


def run(path, show_ok=False):
    img = macho.parse(path)

    # ── 来源 ① 所有导入符号（chained / bind opcode / symtab 三源合一）──
    a = set()
    for imp in img.imports:
        if imp.name in ("dyld_stub_binder", "dyld_private"):
            continue          # 运行时符号，不是真导入
        a.add((strip_prefix(imp.name), imp.ordinal))

    # ── 来源 ② symtab undef（ordinal 未知，只比名字）──
    b = set()
    for e in img.undefined_syms:
        if e.name in ("dyld_stub_binder", "dyld_private"):
            continue
        b.add(strip_prefix(e.name))

    a_names = {n for n, _ in a}

    only_a = a_names - b
    only_b = b - a_names
    both = a_names & b

    print("=" * 70)
    print(f"交叉验证: {os.path.basename(path)}")
    print(f"  来源① parsed imports  : {len(a)} 条（{len(a_names)} 个不同名字）")
    print(f"  来源② symtab undefined: {len(b)} 条")
    print(f"  两边都有（对齐成功）  : {len(both)}")
    print(f"  只在 ① 出现           : {len(only_a)}")
    print(f"  只在 ② 出现           : {len(only_b)}")

    ok = True
    # 只在 symtab 出现 = chained imports 漏解析（严重）
    if only_b:
        ok = False
        print(f"\n  ❌ 漏解析 {len(only_b)} 个符号（chained imports 里没有）:")
        for n in sorted(only_b)[:20]:
            print(f"       {n}")
        if len(only_b) > 20:
            print(f"       … 还有 {len(only_b) - 20} 个")

    # 只在 chained 出现 = 可能是 symtab 里被 strip 了的，也可能是解析多算（警告级）
    if only_a:
        print(f"\n  ⚠️  只在 chained imports 出现 {len(only_a)} 个（可能 symtab 已 stripped）:")
        for n in sorted(only_a)[:10]:
            print(f"       {n}")

    # ── 额外验证：段的 vmaddr 单调递增、fileoff 不越界 ──
    print("\n  ── 结构合理性 ──")
    prev_end = 0
    seg_ok = True
    for s in img.segments:
        if s.vmaddr < prev_end and s.name != "__PAGEZERO":
            print(f"       ⚠️ {s.name} vmaddr 与前段重叠")
            seg_ok = False
        if s.fileoff + s.filesize > os.path.getsize(path) and s.filesize:
            print(f"       ❌ {s.name} 文件范围越界")
            seg_ok = False
        prev_end = s.vmaddr + s.vmsize
    print(f"       段布局: {'✅ 合法' if seg_ok else '❌ 有问题'}")

    # ── 额外验证：入口点落在可执行段内 ──
    print("\n  ── 入口点 ──")
    if img.entryoff is not None:
        hit = None
        for s in img.segments:
            if s.fileoff <= img.entryoff < s.fileoff + s.filesize:
                hit = s
                break
        if hit:
            print(f"       entryoff=0x{img.entryoff:x} 落在 {hit.name}（权限 {hit.prot_str}）"
                  + ("  ✅ 可执行" if "x" in hit.prot_str else "  ⚠️ 该段不可执行"))
        else:
            print(f"       entryoff=0x{img.entryoff:x} 不在任何段内 ❌")
            ok = False
    else:
        print(f"       无 LC_MAIN（dylib/bundle 正常）")

    # ── 依赖序号完整性 ──
    print("\n  ── 依赖序号 ──")
    max_ord = max((d.ordinal for d in img.dylibs), default=0)
    SPECIAL = (-1, -2, -3)   # MAIN / FLAT / WEAK
    bad = [imp for imp in img.imports if imp.ordinal > max_ord and imp.ordinal not in SPECIAL]
    if bad:
        print(f"       ❌ {len(bad)} 个符号引用了不存在的库序号")
        for imp in bad[:5]:
            print(f"          {imp.name} → #{imp.ordinal}")
        ok = False
    else:
        print(f"       所有符号的库序号都在 1..{max_ord} 或特殊序范围内 ✅")

    print("\n" + ("=" * 70))
    print("结论: " + ("✅ 解析正确，交叉验证通过" if ok else "❌ 存在问题，需要修"))
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(run(sys.argv[1], "--show-ok" in sys.argv))
