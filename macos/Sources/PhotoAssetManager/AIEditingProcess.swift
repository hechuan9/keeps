import Foundation
import Darwin
import KeepsAPI

struct AIEditingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    let logDirectory: URL?
    let retryable: Bool
    init(_ message: String, logDirectory: URL? = nil, retryable: Bool = false) {
        self.message = message
        self.logDirectory = logDirectory
        self.retryable = retryable
    }

    static func process(_ result: AIEditingProcess.Result, job: URL) -> AIEditingFailure {
        let text = (result.errors + "\n" + result.output).lowercased()
        func contains(_ patterns: [String]) -> Bool { patterns.contains { text.contains($0) } }
        let message: String
        if contains(["error loading config", "failed to parse", "invalid type:"]) {
            message = "AI 工具配置有误，无法启动调色。请更新 Keeps；若已是最新版，请提供诊断日志。"
        } else if contains(["insufficient_quota", "usage limit", "quota exceeded", "credit balance"]) {
            message = "AI 账户的可用额度已用完。请检查修图账户的额度，恢复后重试。"
        } else if contains(["401", "unauthorized", "token expired", "refresh_token", "authentication", "not logged in"]) {
            message = "AI 登录已失效或未完成。请打开「AI 设置」重新登录修图账户，再重试。"
        } else if contains(["model_not_found", "model is not supported", "model does not exist", "do not have access to model"]) {
            message = "当前账户无法使用所选 AI 模型。请在「AI 设置」确认登录账户并测试连接；仍然失败时请提供诊断日志。"
        } else if contains(["429", "rate limit", "too many requests"]) {
            message = "AI 服务请求过于频繁。请稍等片刻后重试。"
        } else if contains(["connection", "network", "timed out", "timeout", "dns", "stream disconnected"]) {
            message = "连接 AI 服务时中断或超时。请检查网络连接，然后重试。"
        } else if contains(["mcp startup", "mcp server", "code-mode-host", "darktable", "failed to reserve virtual memory"]) {
            message = "本机调色工具未能正常运行。请更新或重新安装 Keeps；仍然失败时请提供诊断日志。"
        } else {
            message = "AI 调色进程意外退出，暂时无法确定原因。请重试；若再次失败，请提供诊断日志（退出码 \(result.exitCode)）。"
        }
        let retryable = contains(["429 too many", "status code: 429", "status 429", "http 429", "rate limit", "rate_limit", "too many requests", "stream disconnected", "dns", "connection reset", "network is unreachable"])
            && !contains(["insufficient_quota", "usage limit", "quota exceeded", "credit balance"])
        return AIEditingFailure(message, logDirectory: job, retryable: retryable)
    }

    static func userMessage(_ error: Error) -> String {
        if let failure = error as? AIEditingFailure { return failure.message }
        if let network = error as? URLError {
            return network.code == .cancelled ? "操作已取消。" : "无法连接 NAS。请检查网络和 NAS 状态，恢复连接后继续。"
        }
        if case KeepsAPIError.http(let code, let body) = error {
            switch code {
            case 401, 403: return "NAS 连接凭证无效或没有访问权限。请结束当前任务，在连接设置中检查凭证后重试。"
            case 404: return "找不到这张照片或底片。请刷新资料库，确认原文件仍然可用后重试。"
            case 409: return "照片或底片已发生变化，本次结果未覆盖。请结束当前任务，刷新资料库后重新调色。"
            case 413: return "调色结果超过 NAS 接收限制，未能保存。请提供诊断日志。"
            case 422 where body.contains("invalid output image dimensions"):
                return "展示图尺寸未通过 NAS 校验。调色结果保留在本机；请更新 Keeps 后重试保存，无需重新调色。"
            case 429: return "NAS 暂时繁忙，正在等待重试。"
            case 500...599: return "NAS 暂时无法保存或读取照片，正在等待服务恢复。"
            default: return "NAS 请求失败（HTTP \(code)）。请重试；仍然失败时请提供诊断日志。"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError: return "Mac 存储空间不足，无法保存调色结果。请释放空间后重试。"
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "Keeps 无法访问所需的本机文件。请检查文件访问权限，仍然失败时请提供诊断日志。"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "调色所需的本机文件已丢失。请结束当前任务后重新调色。"
            default: break
            }
        }
        return "操作未能完成，暂时无法确定原因。请重试；若再次失败，请提供诊断日志。"
    }
}

private final class AIProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var ended = false
    private let captureLines: Bool
    private var pendingLine = Data()
    private var lines: [String] = []
    init(captureLines: Bool = false) { self.captureLines = captureLines }
    func drainLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let result = lines; lines.removeAll(keepingCapacity: true); return result
    }
    func finish() { lock.lock(); ended = true; lock.unlock() }
    func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return ended }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if captureLines {
            pendingLine.append(data)
            while let end = pendingLine.firstIndex(of: 10) {
                lines.append(String(decoding: pendingLine[..<end], as: UTF8.self))
                pendingLine.removeSubrange(...end)
            }
        }
        if bytes.count > 32 * 1024 * 1024 { bytes.removeFirst(bytes.count - 32 * 1024 * 1024) }
    }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@MainActor final class AIEditingProcess {
    struct Result { let exitCode: Int32; let output: String; let errors: String }
    private var process: Process?
    private var cancelled = false
    private(set) var lastOutput = ""
    private(set) var lastErrors = ""

    static func environment(home: URL, ambient: [String: String]) -> [String: String] {
        // Authentication and configuration are supplied exclusively by Keeps.
        var environment: [String: String] = ["CODEX_HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        for key in ["HOME", "TMPDIR", "USER", "LOGNAME", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let value = ambient[key] { environment[key] = value }
        }
        return environment
    }

    func run(executable: URL, arguments: [String], home: URL, directory: URL, input: String? = nil,
             timeout: TimeInterval, progress: ((String) -> Void)? = nil, onEvent: ((String) -> Void)? = nil) async throws -> Result {
        guard process == nil else { throw AIEditingFailure("已有 AI 进程正在运行。") }
        cancelled = false
        lastOutput = ""; lastErrors = ""
        let child = Process(), outputPipe = Pipe(), errorPipe = Pipe(), inputPipe = Pipe()
        let output = AIProcessOutput(captureLines: onEvent != nil), errors = AIProcessOutput()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = Self.environment(home: home, ambient: ProcessInfo.processInfo.environment)
        child.standardOutput = outputPipe; child.standardError = errorPipe; child.standardInput = inputPipe
        defer {
            if child.isRunning {
                for pid in processTree(child.processIdentifier).reversed() { Darwin.kill(pid, SIGKILL) }
            }
            lastOutput = output.text(); lastErrors = errors.text()
            try? inputPipe.fileHandleForWriting.close()
            process = nil
        }
        try child.run()
        process = child
        for (handle, collector) in [(outputPipe.fileHandleForReading, output), (errorPipe.fileHandleForReading, errors)] {
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    collector.append(data)
                }
                collector.finish()
            }
        }
        if let input { try inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        var stoppedError: AIEditingFailure?
        while child.isRunning {
            for line in output.drainLines() { onEvent?(line) }
            progress?(output.text() + "\n" + errors.text())
            if cancelled || Task.isCancelled || Date() >= deadline {
                let wasCancelled = cancelled || Task.isCancelled
                let descendants = processTree(child.processIdentifier)
                for pid in descendants.reversed() { Darwin.kill(pid, SIGTERM) }
                let stopDeadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < stopDeadline { try? await Task.sleep(for: .milliseconds(100)) }
                for pid in descendants.reversed() { Darwin.kill(pid, SIGKILL) }
                stoppedError = AIEditingFailure(wasCancelled ? "操作已取消。" : "操作超时，请检查网络后重试。")
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let drainDeadline = Date().addingTimeInterval(5)
        while !output.isFinished() || !errors.isFinished() {
            guard Date() < drainDeadline else { throw AIEditingFailure("子进程输出未能结束。") }
            try? await Task.sleep(for: .milliseconds(20))
        }
        for line in output.drainLines() { onEvent?(line) }
        progress?(output.text() + "\n" + errors.text())
        if let stoppedError { throw stoppedError }
        return Result(exitCode: child.terminationStatus, output: output.text(), errors: errors.text())
    }

    func cancel() { cancelled = true }

    func stopForExit() {
        cancelled = true
        guard let process, process.isRunning else { return }
        for pid in processTree(process.processIdentifier).reversed() { Darwin.kill(pid, SIGKILL) }
    }

    private func processTree(_ root: Int32) -> [Int32] {
        // Stop the renderer and MCP descendants too, so cancellation releases source files.
        let listing = Process(), pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-axo", "pid=,ppid="]
        listing.standardOutput = pipe
        do { try listing.run() } catch { return [root] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
        let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let fields = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            return fields.count == 2 ? (fields[0], fields[1]) : nil
        }
        var descendants: [Int32] = [root]
        var offset = 0
        while offset < descendants.count {
            descendants.append(contentsOf: pairs.filter { $0.1 == descendants[offset] }.map(\.0))
            offset += 1
        }
        return descendants
    }
}
