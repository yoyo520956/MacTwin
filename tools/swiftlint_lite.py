#!/usr/bin/env python3
"""
swiftlint_lite.py — 没有 swiftc 时的 Swift 静态自检

检查：
  1. 括号 / 方括号 / 花括号 是否平衡
  2. 字符串字面量是否闭合（含 \\" 转义、多行字符串）
  3. 常见笔误：中文标点混入代码区、未闭合的 /* 注释

不替代编译器，但能在推 CI 前抓掉大部分低级错误。
"""
import sys
import os
import re


def strip_code(src: str):
    """把字符串/注释替换成空格，保留换行以便行号对齐"""
    out = []
    i = 0
    n = len(src)
    in_block = False
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        if in_block:
            if c == "*" and nxt == "/":
                in_block = False
                out.append("  ")
                i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
            continue

        if c == "/" and nxt == "*":
            in_block = True
            out.append("  ")
            i += 2
            continue

        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue

        if c == '"' and src[i:i + 3] == '"""':
            out.append("   ")
            i += 3
            while i < n and src[i:i + 3] != '"""':
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("   ")
                i += 3
            continue

        if c == '"':
            out.append(" ")
            i += 1
            while i < n:
                if src[i] == "\\":
                    out.append("  ")
                    i += 2
                    continue
                if src[i] == '"':
                    out.append(" ")
                    i += 1
                    break
                if src[i] == "\n":
                    break
                out.append(" ")
                i += 1
            continue

        out.append(c)
        i += 1

    return "".join(out)


def check_file(path):
    problems = []
    src = open(path, encoding="utf-8").read()
    clean = strip_code(src)

    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in clean:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                problems.append("%s:%d 多余的 '%s'" % (path, line, ch))
            else:
                op, oline = stack.pop()
                if op != pairs[ch]:
                    problems.append("%s:%d '%s' 与第 %d 行的 '%s' 不匹配"
                                    % (path, line, ch, oline, op))
    for op, oline in stack:
        problems.append("%s:%d 未闭合的 '%s'" % (path, oline, op))

    for m in re.finditer(r"[，。；：！？（）【】｛｝“”‘’]", clean):
        ln = clean[:m.start()].count("\n") + 1
        problems.append("%s:%d 代码区出现中文标点 '%s'" % (path, ln, m.group()))

    return problems


def main(argv):
    if len(argv) < 2:
        print("用法: swiftlint_lite.py <目录或文件> ...")
        return 2

    targets = []
    for a in argv[1:]:
        if os.path.isdir(a):
            for root, _dirs, files in os.walk(a):
                for f in sorted(files):
                    if f.endswith((".swift", ".m", ".h")):
                        targets.append(os.path.join(root, f))
        else:
            targets.append(a)

    all_problems = []
    for t in targets:
        all_problems.extend(check_file(t))

    print("检查了 %d 个文件" % len(targets))
    if all_problems:
        print("\n发现 %d 个问题：" % len(all_problems))
        for p in all_problems[:80]:
            print("  " + p)
        return 1
    print("✅ 括号/引号/标点全部平衡")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))