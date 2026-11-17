# MacTwin

**在 iPhone 上跑 macOS 应用。无系统镜像。纯符号级实时绑定。**

---

## 这是什么

MacTwin 是一个 iOS 容器：导入 macOS `.app`，自研 Mach-O 加载器把它的
每一个库导入符号**在加载时直接绑到 iOS 上同名的 Darwin 符号**，然后用
ObjC 写的 AppKit 兼容层 + UIKit 把它的窗口画出来。

没有虚拟机、没有系统镜像、没有 CPU 指令翻译。

## 核心依据

iOS 与 macOS 共享同一 CPU 架构（arm64）、同一内核家族（Darwin/XNU）、
同一 C ABI。所以 macOS 二进制的机器码 iPhone 可以直接执行。真正缺的只有
三样：**Mach-O 加载器**、**AppKit 等 GUI framework**、**fork/exec**。

前两样可以自己造（本项目做的事），第三样只能绕。

## 当前状态

| 阶段 | 状态 |
|---|---|
| **M0** Mach-O 解析器（Python 验证版） | ✅ 完成，三份真二进制交叉验证通过 |
| P1 Mach-O 加载器（Swift，跑起来） | 🔜 下一步 |
| P2 符号直通层 | ⬜ |
| P3 AppKit 兼容层 + 窗口 | ⬜ |

见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 与 [docs/M0-VERIFICATION.md](docs/M0-VERIFICATION.md)。

## 工具

```bash
# 单架构切片（universal2 → arm64）
python3 tools/thin.py <文件> --arch arm64 -o out

# 解析 + 缺口报告
python3 tools/macho.py <arm64 Mach-O> [--verbose] [--json]

# 交叉验证解析正确性（两份独立符号来源必须对齐）
python3 tools/crosscheck.py <arm64 Mach-O>
```

## 实测缺口（不是估算）

| 样本 | 导入符号 | iOS 直通 | 真缺口 | 结论 |
|---|---|---|---|---|
| jq 1.8.2 | 74 | 74 (100%) | 0% | ✅ 可跑 |
| VS Code Electron Framework (196MB) | 5124 | 2071 (40%) | **6.6%** | 🔧 需 shim |

实测方法、案例与三个关键发现见 [M0-VERIFICATION.md](docs/M0-VERIFICATION.md)。

## 许可

MIT
