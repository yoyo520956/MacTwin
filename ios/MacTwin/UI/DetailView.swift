//  DetailView.swift
//  MacTwin — 单个二进制的详情

import SwiftUI

struct DetailView: View {
    let item: BinaryItem
    @EnvironmentObject var state: AppState

    var body: some View {
        List {
            Section("基本信息") {
                kv("文件名", item.name)
                kv("大小", item.sizeText)
                kv("架构", item.arch)
                kv("类型", item.kind)
                kv("最低系统", item.minOS.isEmpty ? "—" : item.minOS)
                kv("Fixup 格式", item.fixupKind)
                kv("导入符号", "\(item.importCount)")
                if let gap = item.gapRatio {
                    kv("估算缺口", String(format: "%.1f%%", gap))
                }
            }

            if let err = item.parseError {
                Section("解析错误") {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    state.run(item)
                } label: {
                    HStack {
                        Spacer()
                        Label("运行", systemImage: "play.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(state.isRunning || !item.isParsed || item.kind != "可执行文件")
            } footer: {
                if item.kind != "可执行文件" {
                    Text("只有「可执行文件」类型才能直接运行。动态库需要被某个程序加载。")
                } else if !state.jitAvailable {
                    Text("⚠️ 当前没有 JIT 权限，运行时会被拒绝。请先到「设置」页按提示开启。")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
                .foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}