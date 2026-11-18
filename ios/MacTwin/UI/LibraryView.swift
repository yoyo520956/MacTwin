//  LibraryView.swift
//  MacTwin — 库（导入的 macOS 二进制）

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @State private var showImporter = false
    @State private var pendingDelete: BinaryItem?

    var body: some View {
        NavigationStack {
            Group {
                if state.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("MacTwin")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.refreshLibrary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let got = url.startAccessingSecurityScopedResource()
                    defer { if got { url.stopAccessingSecurityScopedResource() } }
                    state.importFile(from: url)
                case .failure(let error):
                    state.statusLine = "选择文件失败：\(error.localizedDescription)"
                }
            }
            .alert("删除这个二进制？", isPresented: .constant(pendingDelete != nil)) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let it = pendingDelete { state.delete(it) }
                    pendingDelete = nil
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("还没有导入任何 macOS 程序")
                .font(.headline)
            Text("点右上角 + 选择 arm64 的 macOS 可执行文件或动态库。\n从 .app 里取的是 Contents/MacOS/ 下的主二进制。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(state.items) { item in
                    NavigationLink {
                        DetailView(item: item)
                    } label: {
                        row(item)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("支持 arm64（Apple Silicon）的 macOS 二进制。x86-64 需要额外的指令翻译层，当前版本不支持。")
            }
        }
    }

    private func row(_ item: BinaryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(item.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let err = item.parseError {
                    Label("无法解析", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    tag(item.arch)
                    tag(item.kind)
                    tag("\(item.importCount) 符号")
                    if let gap = item.gapRatio {
                        tag(String(format: "缺口 %.0f%%", gap),
                            color: gap < 5 ? .green : (gap < 20 ? .orange : .red))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}