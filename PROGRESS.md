# MacTwin 开发进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | Mach-O 解析器 + 真二进制交叉验证 | ✅ 完成（CI 44116172427 绿） |
| P1 | Swift 加载器（解析/mmap/fixup/绑定） | 🔄 进行中 |
| P2 | stdio 捕获 + exit/fork 拦截 | ⬜ |
| P3 | iOS App UI（导入/运行/输出/JIT） | ⬜ |
| P4 | Xcode 工程 + CI 构建 IPA | ⬜ |
| P5 | 最小 AppKit shim | ⬜ |
| P6 | 真样本验证（VS Code Code 68KB） | ⬜ |
| P7 | 打磨 + 自检 + 交付 | ⬜ |

## 实测基线（来自 M0）

| 样本 | 导入 | 真缺口 |
|---|---|---|
| jq 1.8.2 | 74 | 0% |
| VS Code Electron FW | 5124 | 6.6% |
| VS Code `Code` | 10 | **0%** |
| orjson | 68 | 0% |

## 阻塞

（暂无）
