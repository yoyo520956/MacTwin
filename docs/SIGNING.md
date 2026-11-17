# 装到 iPhone

MacTwin 是未签名的 IPA，需要**你自己签名**并安装到设备上。有 3 条路：

## 前置：JIT entitlement

iOS 上跑加载的 arm64 代码页需要 JIT 权限。有三种开法（任选其一）：

1. **AltStore + 开发者证书**（推荐）
   - 下载 https://altstore.io/，用你的 Apple ID 登录
   - 把 MacTwin.ipa 拖进 AltStore 桌面端，签名 → 同步到手机
   - AltStore 会自动带上 `get-task-allow` 和 `dynamic-codesigning`

2. **SideStore**（iOS 上签 iOS 证书）
   - 需要 iPad 或有 Xcode 的 Mac 作为签名源
   - 装 SideStore，导入 MacTwin.ipa，签名

3. **Sideloadly / ESign**（快速但 7 天到期，免费证书）
   - 拖 IPA 上传，选「无签名」

> **关键**：签名时必须勾选或保留 `MacTwin.entitlements` 里的：
>   - `get-task-allow: true`（让调试器可以 attach，StikJIT 靠这个）
>   - `dynamic-codesigning: true`（iOS 14+ 允许自签名 App 动态改代码页）

## 装机后开启 JIT（一次性）

1. 手机连上电脑（USB 或 Wi-Fi）
2. 启动 StikJIT 助手（或者用 StikDebug 命令行）
3. attach 到 MacTwin 进程
4. 点 "Enable JIT" 或 `task_set_exception_ports` + `task_set_memory_entry_points`

之后 App 里「设置」页点「重新检测」，如果显示「JIT 已就绪」，
就能点运行了。

## 首次运行测试

1. 点「库」→ 右上角 +
2. 选择 `jq`（或自己编的 arm64 macOS `hello` 二进制）
3. 进详情页 → 点「运行」
4. 「运行」页应该看到输出
