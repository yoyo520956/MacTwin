# MacTwin — 架构

> 在 iOS 上运行 macOS 应用容器。无系统镜像。纯符号级实时绑定。

---

## 0. 一句话

MacTwin 是一个 iOS 用户态容器：导入 macOS 的 `.app`，自己加载它的 Mach-O，
把它的每一个库导入符号**在运行时直接绑到 iOS 上同名的 Darwin 符号**，缺失的
AppKit 用自己的 ObjC 实现补上，然后用 UIKit 把它的窗口画出来。

没有虚拟机，没有系统镜像，没有 CPU 模拟。

---

## 1. 为什么可能（技术前提）

iOS 与 macOS 共享：

| 层 | 状态 |
|---|---|
| CPU 架构 | arm64，同一指令集，**机器码可直接执行** |
| 内核家族 | Darwin/XNU，syscall 语义同源 |
| C ABI | Darwin AAPCS64，参数/寄存器/栈布局一致 |
| libSystem | `malloc` / `pthread_*` / `open` / `mmap` / `mach_*` 等同名同 ABI |
| libdispatch | `dispatch_*` 全系存在 |
| CoreFoundation | `CFString*` / `CFRunLoop*` / `CFArray*` 基本全量存在 |
| CoreGraphics | 几乎全量存在 |
| QuartzCore | `CALayer` / `CATransaction` 存在 |
| Metal | 存在（GPU 驱动不同，但 API 层一致） |
| Objective-C runtime | 完整（`objc_msgSend` / 类 / category / KVC / KVO） |
| Swift runtime | 存在（版本需匹配，见 §6 风险） |

**结论**：真正要自己造的东西只有三块 —— **加载器**、**缺口符号**、**AppKit/窗口服务**。

---

## 2. 三层结构

```
┌──────────────────────────────────────────────────────────┐
│  UI 层        SwiftUI / UIKit                             │
│  Library · Installed · Running · Settings                 │
├──────────────────────────────────────────────────────────┤
│  AppKitShim   ObjC，映射到 UIKit                          │
│  NSApplication · NSWindow · NSView · NSButton · NSTextField │
│  NSMenu · NSOpenPanel · NSApplicationMain                 │
├──────────────────────────────────────────────────────────┤
│  Runtime      路径映射 · 进程模拟 · JIT · 环境            │
│  PathShim · ProcessShim · JITManager · LaunchServicesShim │
├──────────────────────────────────────────────────────────┤
│  Loader       Mach-O 加载（纯用户态）                      │
│  MachOImage · SegmentMapper · FixupResolver · SymbolBinder│
├──────────────────────────────────────────────────────────┤
│  iOS Darwin    libSystem · CF · CG · QZ · Metal · ObjC     │
└──────────────────────────────────────────────────────────┘
```

---

## 3. 加载器（核心，P0/P1）

### 3.1 为什么不能用系统 dyld

iOS 的 `dyld` 只加载：
- 系统签名 + 在 shared cache 里的库
- 或 App 自身签名内的 framework

第三方 `.app` 的 Mach-O **不在** shared cache，也没有我们的签名，`dlopen` 直接失败。
所以必须自己实现映射与重定位。

### 3.2 加载流程

```
1. 读文件 → 解析 mach_header_64
2. 遍历 load commands
   ├─ LC_SEGMENT_64        → 记录各段 vmaddr/vmsize/fileoff/filesize/initprot
   ├─ LC_SYMTAB            → 符号表与字符串表
   ├─ LC_DYSYMTAB          → 导入符号分组（local/ext/undef）
   ├─ LC_DYLD_INFO_ONLY    → 老的 bind/rebase opcode（若有）
   ├─ LC_DYLD_CHAINED_FIXUPS → 现代 chained fixups（macOS 12+ 默认）
   ├─ LC_LOAD_DYLIB        → 依赖库列表
   └─ LC_MAIN              → 入口点
3. mmap 各段到选定基址（必要时 ASLR 偏移）
4. 处理 fixups：把每个需要绑定的指针解析成真实地址
5. mprotect：__TEXT 可读可执行，__DATA 可读写
6. 调 LC_MAIN 入口（或 dlsym("main")）
```

### 3.3 两种 fixup 格式都要支持

| 格式 | 出现 | 处理 |
|---|---|---|
| `LC_DYLD_INFO_ONLY` (bind/rebase opcode) | macOS 11 及更老 | 解释 opcode 流 |
| `LC_DYLD_CHAINED_FIXUPS` | macOS 12+ 默认 | 走 `dyld_chained_starts_in_image` |

现在绝大多数 Mac 程序是 chained fixups，**优先实现它**，老格式后补。

### 3.4 符号绑定策略（"实时翻译"的实质）

对每个未定义符号（`_malloc` → `malloc`）：

```swift
// 1. 本 App 内自研实现（AppKit 等）
if let p = ShimTable.lookup(name) { return p }

// 2. iOS 系统符号 —— 直接 dlsym
if let p = dlsym(RTLD_DEFAULT, name) { return p }

// 3. 依赖的第三方 dylib（App 自带的 Frameworks/）
if let p = loadedImages.lookup(name) { return p }

// 4. 全都没有 → 记录缺口，返回 stub（首次调用即报 ENOSYS 并写日志）
return MissingSymbols.stub(for: name)
```

**这一层没有指令翻译，只有指针填充。运行期开销 = 一次间接跳转。**

这就是"高效实时翻译"：翻译发生在**加载时**（一次），不是执行时（每次）。
和 Rosetta 那种逐指令翻译是两码事。

### 3.5 缺口统计是关键指标

加载器必须输出一份报告：

```
Symbols: 1247 total
  shim    : 180   (AppKit 自研)
  system  : 892   (iOS 直通)
  bundle  :  95   (App 自带 framework)
  missing :  80   (16.4% gap)   ← 决定这个 app 能不能跑
```

**这个 gap 率就是可行性判断标准。** gap < 5% 大概率能跑，> 30% 基本无望。

---

## 4. 路径与文件系统（P2）

macOS 程序硬编码绝对路径。需要一层翻译：

| macOS 路径 | MacTwin 内映射 |
|---|---|
| `/Applications/X.app` | `<container>/Apps/X.app` |
| `~/Library`, `~/Documents` | `<container>/Home/Library`, `/Home/Documents` |
| `/tmp`, `/var/tmp` | `<container>/tmp` |
| `/usr/lib/dyld`, `/usr/lib/libSystem.B.dylib` | 虚拟（不真实存在，由加载器拦截） |
| `/System/Library/Frameworks/*` | 虚拟（由 Sh림 拦截） |

实现方式：hook libSystem 的路径类函数（`open`/`stat`/`access`/`fopen`/`opendir`…），
入口做路径重写。这比内核级 chroot 简单且够用。

---

## 5. AppKit 兼容层（P3/P5）

用 ObjC 写（因为 ObjC runtime 是原生红利，Mac 程序发的消息天然能接住）。

### 5.1 最小可用集合（T2/T3 目标）

| 类 | 映射到 |
|---|---|
| `NSApplication` | 自研事件循环（跑在 `CFRunLoop`，iOS 有 CF） |
| `NSWindow` | `UIWindow` + 自绘标题栏 |
| `NSView` | `UIView` 子类（含 `frame`/`bounds`/`superview`/`subviews`） |
| `NSButton` | `UIButton` |
| `NSTextField` | `UILabel` + 可编辑模式时 `UITextField` |
| `NSMenu` | 自绘下拉 |
| `NSOpenPanel` | `UIDocumentPickerViewController` |
| `NSApplicationMain` | 启动入口 shim |
| `NSColor` / `NSFont` | 映射到 UIColor / UIFont |

### 5.2 为什么 Electron 应用是第一优先目标（T3）

Electron 应用的渲染完全在 Chromium 内部（自绘 + Metal），
对 AppKit 的依赖仅限：

- `NSApplication`（事件循环）
- `NSWindow`（一个宿主窗口）
- `NSView`（宿主 view）
- 鼠标/键盘事件投递
- 少量 `NSScreen` / `NSWorkspace` / 剪贴板

**也就是说：只要 §5.1 的最小集合做好了，Electron 应用就能起来。**

这是"跑大部分 macOS 软件"最现实的一条路。

---

## 6. 技术风险（已知，逐条有对策）

| # | 风险 | 影响 | 对策 |
|---|---|---|---|
| R1 | **必须 JIT**（可执行页需 `CS_DEBUGGED`） | 无 JIT 就无法执行代码页 | 内置 JIT 获取流程，兼容 StikDebug attach；用 `MAP_JIT` + `mprotect` |
| R2 | **无 fork/exec** | 会 spawn 子进程的 CLI 跑不了 | 单进程模拟：把子进程换成线程 + 状态机；实在不行标不支持 |
| R3 | **Swift runtime 版本差** | Swift 写的 .app 可能链接失败 | 优先用 App 自带的 `Frameworks/libswift*.dylib`；不行则 ABI 桥接 |
| R4 | **AppKit 覆盖度** | 复杂 GUI 应用跑不动 | 按 T1→T5 分级推进，用符号 gap 报告决定支持范围 |
| R5 | **代码签名校验** | 部分 App 有硬化运行时 | 加载器不校验签名，直接映射 |
| R6 | **WindowServer 不存在** | 任何依赖 XPC 显示服务的路径都断 | 全部由 AppKitShim 拦截，不落到真实 XPC |
| R7 | **4GB 内存设备** | 大 App 可能 OOM | 限制并发、大文件 mmap 惰性、支持内存压力降级 |

---

## 7. 不做的事（明确边界）

- 不加载 x86-64 二进制（需要指令翻译，另立项目）
- 不实现完整 AppKit（只做被实际用到的子集，按 gap 报告增长）
- 不模拟 macOS 内核（不需要，因为不跑系统）
- 不打包系统镜像（架构上就不需要）
- 不支持 T5 级大型商业软件（Photoshop 等）

---

## 8. 验收里程碑

| 阶段 | 判据 |
|---|---|
| M0 | 正确解析任意 arm64 macOS Mach-O，符号表/chained fixups 100% 准确 |
| M1 | 自己编的 `hello`（arm64 macOS）在 iPhone 上打印出 `hello from macOS` |
| M2 | 跑通 `jq`，输入 JSON 输出正确结果 |
| M3 | 跑通一个真实 App 的加载：gap 报告 < 10% |
| M4 | 看到一个自研 demo App 的 NSWindow 出现在屏幕上 |
| M5 | 跑通一个 Electron 应用（窗口 + 交互） |
