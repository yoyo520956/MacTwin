# MacTwin 开发进度

## 当前状态

**首个可装 IPA 已出**（v0.1.0，未签名，macOS CI 编译全绿）。
主二进制是 arm64 Mach-O executable，SwiftUI 三 Tab 界面。

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | Mach-O 解析器 + 真二进制交叉验证 | ✅ |
| P1 | Swift 加载器 | ✅ |
| P2 | 运行时（stdio 捕获 + 线程执行 + exit 拦截） | ✅ |
| P3 | iOS App UI（导入/运行/输出/JIT） | ✅ |
| P4 | Xcode 工程 + CI 构建 IPA | ✅ |
| P5 | 最小 AppKit shim | ⬜ |
| P6 | 真样本验证（VS Code Code 68KB） | ⬜ |
| P7 | 打磨 + 自检 + 交付 | 🔄 进行中 |

## 本轮 CI

- 44132149462 Build IPA success (cefbb8fa)
- 44132149454 Verify Parser success

## 交付物

- `/var/minis/attachments/MacTwin-v0.1.0-unsigned.ipa`
- sha256: `2c8f3a0cc928bd242a8746235b78676892c1c84380d0337f951d2f2d185e3045`
- 主二进制：Mach-O 64-bit arm64 executable
- 安装指南：docs/SIGNING.md

## 阻塞 / 需要真机验证

- 装机后 JIT entitlement 是否生效（AltStore 带不带 dynamic-codesigning 决定）
- 首次跑真 arm64 二进制的实际表现（jq / 自编 hello）
- 任何 SIGSEGV / SIGBUS 需要真机调试

## 下一步

- P5: 至少让 AppKit 的 `NSApplicationMain` 能开一个窗口（不闪退）
- P6: 把 VS Code 的 `Code` 68KB 启动器打进资源里作为内置 demo
- P7: 加 crash log 记录 + 错误路径全走一遍自检
