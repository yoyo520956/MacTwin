//  AppState.swift
//  MacTwin — 全局状态

import Foundation
import SwiftUI

/// 一个已导入的二进制
struct BinaryItem: Identifiable, Hashable {
    let id: String                  // 相对路径
    let name: String
    let url: URL
    let size: Int64
    var arch: String = "—"
    var kind: String = "—"
    var importCount: Int = 0
    var gapRatio: Double? = nil
    var parseError: String? = nil
    var minOS: String = ""
    var fixupKind: String = "—"

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    var isParsed: Bool { parseError == nil && arch != "—" }
}

@MainActor
final class AppState: ObservableObject {
    @Published var items: [BinaryItem] = []
    @Published var jitAvailable: Bool = false
    @Published var jitStrategy: String = "未检测"
    @Published var statusLine: String = ""

    // 运行状态
    @Published var isRunning = false
    @Published var output: String = ""
    @Published var exitCode: Int32? = nil
    @Published var runningItem: BinaryItem? = nil
    @Published var bindReport: String = ""

    let loader = Loader()
    private var runtime: MacTwinRuntime?
    private var loaded: LoadedImage?

    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var binariesURL: URL {
        let u = documentsURL.appendingPathComponent("Binaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init() {
        seedBuiltInDemo()
        refreshLibrary()
        probeJIT()
    }

    /// 首次启动把打包进 IPA 的内置 demo 复制进库
    func seedBuiltInDemo() {
        let fm = FileManager.default
        var seeded: [String] = []
        var failed: [String] = []

        for name in ["hello-macos", "hello-gui"] {
            let dest = binariesURL.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            var source = Bundle.main.url(forResource: name, withExtension: nil)
            if source == nil {
                source = Bundle.main.resourceURL?.appendingPathComponent(name)
            }
            guard let url = source else { continue }
            do {
                try fm.copyItem(at: url, to: dest)
                seeded.append(name)
            } catch {
                failed.append(name)
            }
        }

        if !seeded.isEmpty {
            statusLine = "已就绪内置 demo：\(seeded.joined(separator: "、"))"
        } else if !failed.isEmpty {
            statusLine = "内置 demo 导出失败：\(failed.joined(separator: "、"))"
        }
    }

    // MARK: - JIT

    func probeJIT() {
        let m = try? JITMemory.allocate(size: Int(vm_page_size))
        if let m = m {
            jitAvailable = m.isExecutable
            jitStrategy = m.strategy.rawValue
            m.deallocate()
        } else {
            jitAvailable = false
            jitStrategy = "分配失败"
        }
    }

    // MARK: - 库

    func refreshLibrary() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: binariesURL.path) else {
            items = []
            return
        }
        var list: [BinaryItem] = []
        for name in names.sorted() {
            let url = binariesURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { continue }   // .app 目录暂不列（P5）
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            var item = BinaryItem(id: name, name: name, url: url, size: size)
            inspect(&item)
            list.append(item)
        }
        items = list
    }

    /// 解析一个文件并填入元信息
    func inspect(_ item: inout BinaryItem) {
        do {
            let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
            let img = try MachOParser.parse(data, path: item.name)
            item.arch = img.archName
            item.kind = filetypeName(img.filetype)
            item.importCount = img.imports.count
            item.minOS = img.minOS
            item.fixupKind = img.hasChainedFixups ? "chained" : (img.hasDyldInfo ? "dyld_info" : "symtab")

            // 粗估缺口：只看符号名是否能被 dlsym 命中
            var miss = 0
            let rtld = UnsafeMutableRawPointer(bitPattern: -2)
            for imp in img.imports where ShimTable.lookup(imp.name) == nil {
                if let r = rtld, dlsym(r, imp.name) == nil { miss += 1 }
            }
            item.gapRatio = img.imports.isEmpty ? 0 : Double(miss) / Double(img.imports.count) * 100
            item.parseError = nil
        } catch let e as MachOParseError {
            item.parseError = e.description
            item.arch = "—"
        } catch {
            item.parseError = "\(error)"
            item.arch = "—"
        }
    }

    private func filetypeName(_ t: UInt32) -> String {
        switch t {
        case MachOConstants.mhExecute: return "可执行文件"
        case MachOConstants.mhDylib: return "动态库"
        case MachOConstants.mhBundle: return "Bundle"
        default: return "type \(t)"
        }
    }

    // MARK: - 导入

    func importFile(from url: URL) {
        let fm = FileManager.default
        let dst = binariesURL.appendingPathComponent(url.lastPathComponent)
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: url, to: dst)
            statusLine = "已导入 \(url.lastPathComponent)"
            refreshLibrary()
        } catch {
            statusLine = "导入失败：\(error.localizedDescription)"
        }
    }

    func delete(_ item: BinaryItem) {
        try? FileManager.default.removeItem(at: item.url)
        refreshLibrary()
    }

    // MARK: - 运行

    func run(_ item: BinaryItem) {
        guard !isRunning else { return }
        output = ""
        exitCode = nil
        bindReport = ""
        runningItem = item
        isRunning = true
        RuntimeState.shared.exitCode = 0

        // 释放上一次加载
        loaded?.unload()
        loaded = nil

        do {
            let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
            let image = try loader.load(data: data, path: item.url.path)
            loaded = image
            bindReport = image.binder.reportText()

            let rt = MacTwinRuntime()
            runtime = rt

            try rt.run(loaded: image,
                       argv: [item.name]) { [weak self] chunk in
                Task { @MainActor in
                    self?.output += chunk
                }
            } completion: { [weak self] code, _ in
                Task { @MainActor in
                    self?.exitCode = code
                    self?.isRunning = false
                }
            }
        } catch {
            isRunning = false
            exitCode = -1
            output = "❌ 运行失败\n\n\(error)\n"
        }
    }

    func stop() {
        runtime?.cancel()
        isRunning = false
        statusLine = "已请求停止"
    }

    var jitHint: String {
        if jitAvailable {
            return "JIT 已就绪（\(jitStrategy)）—— 加载的代码页可以执行。"
        }
        return """
        当前没有 JIT 权限，加载的代码页无法执行。

        开启方式（任选其一）：
        • 用 StikDebug 连上设备，选择 MacTwin 并点 Enable JIT
        • 用 SideStore / AltStore 安装时勾选「启用 JIT」
        • 用 StikJIT 的 JIT 助手附加本 App

        开启成功后回到本页，点「重新检测」。
        """
    }
}