//  SettingsView.swift
//  MacTwin — 设置与 JIT 引导

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: state.jitAvailable
                              ? "bolt.fill.circle.fill" : "bolt.slash.circle.fill")
                            .font(.title2)
                            .foregroundStyle(state.jitAvailable ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.jitAvailable ? "JIT 已就绪" : "JIT 未开启")
                                .font(.headline)
                            Text(state.jitStrategy)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重新检测") { state.probeJIT() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } header: {
                    Text("执行能力")
                } footer: {
                    Text(state.jitHint)
                }

                Section("怎么用") {
                    step(1, "导入", "点「库」右上角 +，选择一个 arm64 的 macOS 二进制。\n从 .app 里取的是 Contents/MacOS/ 下的那个文件。")
                    step(2, "确认可跑", "详情页会显示架构、导入符号数、估算缺口。缺口越小越可能跑起来。")
                    step(3, "运行", "点「运行」，输出会实时出现在「运行」页。")
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("加载方式")
                        Spacer()
                        Text("自研 Mach-O 加载器").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("转译方式")
                        Spacer()
                        Text("符号级运行时绑定").foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("""
                    MacTwin 不含任何 Apple 系统镜像，也不模拟 macOS 内核。它把你的 \
                    arm64 macOS 二进制的每一个库导入符号，在加载时直接绑到 iOS 上\
                    同名的 Darwin 符号上。因为 iOS 与 macOS 同架构、同内核家族、\
                    同 C ABI，这层绑定没有指令翻译开销。
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("原理")
                }
            }
            .navigationTitle("设置")
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}