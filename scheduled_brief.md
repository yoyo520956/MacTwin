# MacTwin 自主开发 — 轮次指令

> 这是给未来的自己看的。每轮定时任务触发时，先读本文件，再读 PROGRESS.md，
> 然后从那一步继续。目标是把 MacTwin 做成能在 iPhone 上真正运行、不闪退的成品。

## 项目定位

**MacTwin 是一个 iOS 容器 App**：导入 macOS `.app`/`.dylib`，自研 Mach-O 加载器
把它的符号绑定到 iOS 同名 Darwin 符号，然后运行它。

- 仓库：`https://github.com/yoyo520956/MacTwin`
- 本地：`/var/minis/workspace/mactwin`
- 分支：`main`
- 无系统镜像、无 CPU 模拟、纯符号级绑定。

## 最终验收标准（唯一重要的）

1. **IPA 能装到 iPhone（SE3 / iOS 18+）**，靠 StikJIT / StikDebug 拿 JIT
2. **App 内导入一个真 macOS arm64 二进制，能加载、能运行、能看到输出**
3. **不闪退、不卡死、不 crash**——任何失败路径都必须返回可读错误，绝不能 SIGABRT
4. UI 至少包含：导入库、运行、查看输出、JIT 引导、设置

## 每轮必做的事

1. `cat PROGRESS.md` 看进度表
2. 找到当前阶段，只推进那一步
3. 写完代码后**本地能验的先验证**：
   - Swift 文件：`node`/`python` 做括号/引号平衡检查（iSH 无 swiftc）
   - 逻辑：把算法在 `tools/` 下写 Python 版本先跑通，再移植
4. `git add -A && git commit && git push`（token 在 `GITHUB_TOKEN`，有效）
5. 更新 `PROGRESS.md`
6. 遇到阻塞：**如实写进 PROGRESS.md 的「阻塞」节**，不要假装完成

## 关键约束

- iSH **没有 Xcode/Swift 编译器**，不能本地编译。所有编译都靠 GitHub Actions
  （`macos-15` runner + `xcodegen`）。CI 红就是代码有问题，不要绕过。
- iOS 上 `dlopen` 第三方 Mach-O 不可能 → 必须**自己 mmap 段 + 手动 fixup**
- 可执行页需要 JIT entitlement；没有 JIT 时必须**优雅降级并提示**，不能崩
- macOS CLI 会调 `exit()`——**必须拦截**，否则终结我们的 App
- `fork`/`execve` iOS 沙箱禁止 → 必须拦截成 stub
- 同一文件不要并行 `file_edit`（有竞态丢 edit 的风险），务必串行

## 已知环境坑

- `github.com` SSL 不通，但 `api.github.com` / `ghcr.io` / PyPI 通
  → push 用 `git push https://x-access-token:$GITHUB_TOKEN@github.com/...`（这条是通的）
- GNU tar 默认不展开通配符，要 `--wildcards`
- git 不提交空目录 → 需要 `.gitkeep` 或说明文件
- Python 复杂脚本 iSH 上 `site` 模块可能失败，必要时 `python3 -S`

## 阶段计划（PROGRESS.md 是权威，此处仅大纲）

- **P1** Swift 加载器：解析 + mmap + fixup + 符号绑定 → 跑通自编 `hello`
- **P2** stdio 重定向捕获输出 + exit/fork 拦截 → CLI 能跑且不崩
- **P3** iOS App UI（SwiftUI）：导入/列表/运行/输出 + JIT 引导
- **P4** Xcode 工程 + CI 构建 IPA
- **P5** 最小 AppKit shim（NSApplication/NSWindow）→ GUI app 有窗口
- **P6** 真样本验证（VS Code 的 `Code` 68KB，10 导入 0 缺口）
- **P7** 打磨 + 自检 + 交付 IPA

## 交付

最终把 IPA 复制到 `/var/minis/attachments/`，并在总结里给出：
- IPA 路径 + sha256
- 装机方式（StikJIT/StikDebug 拿 JIT → SideStore/AltStore 装）
- **已验证能跑什么、不能跑什么**（诚实）