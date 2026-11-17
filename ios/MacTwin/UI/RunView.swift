//  RunView.swift
//  MacTwin — 运行与输出

import SwiftUI

struct RunView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                outputView
            }
            .navigationTitle("运行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if state.isRunning {
                        Button("停止", role: .destructive) { state.stop() }
                    } else if !state.output.isEmpty {
                        Button {
                            state.output = ""
                            state.exitCode = nil
                            state.bindReport = ""
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let item = state.runningItem {
                    Image(systemName: state.isRunning ? "hourglass" : "doc")
                    Text(item.name)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                } else {
                    Text("还没有运行任何程序")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isRunning {
                    ProgressView().controlSize(.small)
                } else if let code = state.exitCode {
                    Text("exit \(code)")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(code == 0 ? Color.green.opacity(0.15) : Color.orange.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(code == 0 ? .green : .orange)
                }
            }
            .font(.subheadline)

            if !state.bindReport.isEmpty {
                DisclosureGroup("符号绑定报告") {
                    Text(state.bindReport)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
        .padding(12)
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(state.output.isEmpty ? "（暂无输出）" : state.output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(state.output.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("bottom")
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .onChange(of: state.output) { _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}