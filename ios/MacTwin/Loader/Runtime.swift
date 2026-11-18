//  Runtime.swift
//  MacTwin — 执行运行时
//
//  三件事，都是为了「不闪退」：
//    1. stdout/stderr 重定向到管道并实时读出来（否则输出全丢）
//    2. 目标 main 跑在独立线程上（exit() 用 pthread_exit 只杀这条线程）
//    3. 无论走哪条路径，都会恢复 stdio 并回调结束状态

import Foundation

final class RunContext {
    let entry: UnsafeMutableRawPointer
    let argv: [String]
    let envp: [String]
    var exitCode: Int32 = 0

    init(entry: UnsafeMutableRawPointer, argv: [String], envp: [String]) {
        self.entry = entry
        self.argv = argv
        self.envp = envp
    }
}

typealias MainFnSignature = @convention(c) (
    Int32,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

enum RunError: Error, CustomStringConvertible {
    case noEntry
    case jitMissing

    var description: String {
        switch self {
        case .noEntry: return "这个二进制没有可调用入口（可能不是命令行可执行文件）"
        case .jitMissing: return "没有 JIT 权限，加载的代码页无法执行。请先用 StikJIT / StikDebug 为 MacTwin 开启 JIT。"
        }
    }
}

final class OutputCapture {
    private var pipeFDs: [Int32] = [-1, -1]
    private var savedStdout: Int32 = -1
    private var savedStderr: Int32 = -1
    private let lock = NSLock()
    private var buffer = ""

    var onText: ((String) -> Void)?

    func start() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        pipeFDs = fds

        savedStdout = dup(STDOUT_FILENO)
        savedStderr = dup(STDERR_FILENO)
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])

        let readFD = fds[0]
        let t = Thread { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(readFD, &chunk, chunk.count)
                if n <= 0 { break }
                let text = String(decoding: chunk[0..<n], as: UTF8.self)
                self?.append(text)
            }
        }
        t.name = "mactwin-stdout"
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func append(_ text: String) {
        lock.lock(); buffer += text; lock.unlock()
        onText?(text)
    }

    var allOutput: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func stop() {
        if savedStdout >= 0 { dup2(savedStdout, STDOUT_FILENO); close(savedStdout); savedStdout = -1 }
        if savedStderr >= 0 { dup2(savedStderr, STDERR_FILENO); close(savedStderr); savedStderr = -1 }
        if pipeFDs[0] >= 0 { close(pipeFDs[0]); pipeFDs = [-1, -1] }
    }
}

/// 线程入口：构造 argv/envp 并调用目标 main
private func mactwinThreadMain(_ arg: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let arg = arg else { return nil }
    let ctx = Unmanaged<RunContext>.fromOpaque(arg).takeRetainedValue()

    var cStrings: [UnsafeMutablePointer<CChar>] = []
    for s in ctx.argv { cStrings.append(strdup(s)) }
    for s in ctx.envp { cStrings.append(strdup(s)) }

    var argvPtrs: [UnsafeMutablePointer<CChar>?] = cStrings.prefix(ctx.argv.count).map { $0 }
    argvPtrs.append(nil)
    var envpPtrs: [UnsafeMutablePointer<CChar>?] = cStrings.dropFirst(ctx.argv.count).map { $0 }
    envpPtrs.append(nil)

    let fn = unsafeBitCast(ctx.entry, to: MainFnSignature.self)
    let code = fn(Int32(ctx.argv.count), &argvPtrs, &envpPtrs)
    ctx.exitCode = code

    for s in cStrings { free(s) }
    RuntimeState.shared.exitCode = code
    return nil
}

final class MacTwinRuntime {

    private(set) var capture = OutputCapture()
    private var context: RunContext?

    func run(loaded: LoadedImage,
             argv: [String],
             onOutput: @escaping (String) -> Void,
             completion: @escaping (Int32, String) -> Void) throws {

        guard let entry = loaded.entry else { throw RunError.noEntry }
        guard loaded.mapping.isExecutable else { throw RunError.jitMissing }

        let env = [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=/var/mobile",
            "TMPDIR=/tmp",
            "LANG=en_US.UTF-8",
            "TERM=xterm-256color",
        ]

        let ctx = RunContext(entry: entry, argv: argv, envp: env)
        context = ctx

        let cap = OutputCapture()
        cap.onText = onOutput
        capture = cap
        cap.start()

        let t = Thread {
            let unmanaged = Unmanaged.passRetained(ctx)
            _ = mactwinThreadMain(unmanaged.toOpaque())
            Thread.sleep(forTimeInterval: 0.2)   // 等管道里最后一点输出
            cap.stop()
            completion(RuntimeState.shared.exitCode, cap.allOutput)
        }
        t.name = "mactwin-runner"
        t.stackSize = 8 * 1024 * 1024
        t.start()
    }

    func cancel() {
        capture.stop()
    }
}