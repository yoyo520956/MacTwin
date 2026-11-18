# MacTwin v0.1.0 — 交付物清单

- **IPA**: /var/minis/attachments/MacTwin-v0.1.0-unsigned.ipa
- **sha256**: `2c8f3a0cc928bd242a8746235b78676892c1c84380d0337f951d2f2d185e3045`
- **主二进制**: Mach-O 64-bit arm64 executable
- **架构**: SwiftUI（TabView: 库 / 运行 / 设置）

## 已实现

- ✅ Mach-O 解析器（chained fixups 64/64_OFFSET + dyld_info bind opcode 双格式）
- ✅ 段 mmap + 拷贝 + fixup 应用 + 符号绑定
- ✅ 防崩 shim（exit/abort/fork/execve/system/dyld_stub_binder）
- ✅ JIT 三级降级（MAP_JIT → 匿名+mprotect → 只读写）
- ✅ stdout/stderr 管道实时捕获
- ✅ 库管理 + 导入 + 元信息 + 缺口率显示
- ✅ 运行 + 退出码 + 实时输出

## 尚未实现（下一步）

- ❌ 完整 AppKit 兼容层（GUI app 需要）
- ❌ .app bundle 目录导入（当前只收单文件）
- ❌ x86-64 二进制支持
- ❌ fork/exec 模拟（现在直接返回 ENOSYS）
- ❌ 真机 JIT 权限验证（需要你在手机上装完 StikJIT 再回测）

## 验证清单

| 项 | 状态 | 说明 |
|---|---|---|
| iSH 静态语法 | ✅ | 括号/引号平衡 |
| CI 编译 | ✅ | Build IPA success |
| CI 交叉验证 | ✅ | M0 解析器 4 样本全对齐 |
| 真机装 | ⏳ | 需要你签字后测试 |
| 真机跑 jq | ⏳ | 需要先装 StikJIT |
