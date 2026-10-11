import Foundation
import Combine
import CryptoKit

@MainActor final class AIEditingSettingsStore: ObservableObject {
    @Published var limits: AIEditingLimits { didSet { limits.save(defaults: defaults) } }
    let usage: AIEditingUsageStore
    private var gradingRunners: [UUID: AIEditingProcess] = [:]
    @Published private(set) var activeGrades = 0
    @Published var batchActive = false
    @Published var usageError: String?
    @Published var expectedEmail: String {
        didSet {
            defaults.set(expectedEmail, forKey: "aiEditing.expectedEmail")
            connectionVerified = false
        }
    }
    @Published private(set) var accountEmail: String?
    @Published private(set) var status = "尚未检查"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var loginURL: URL?
    @Published private(set) var runtimeReady = false
    @Published private(set) var connectionVerified = false
    @Published private(set) var resultPreview: URL?
    @Published private(set) var resultSummary: String?
    let logDirectory: URL
    let root: URL
    let runtime: URL
    let codeRuntime: URL
    private let defaults: UserDefaults
    private let runner = AIEditingProcess()
    private var home: URL { root.appendingPathComponent("codex", isDirectory: true) }
    private var executable: URL { codeRuntime.appendingPathComponent("codex") }
    private let model = "gpt-6-luna"

    init(root: URL? = nil, runtime: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.limits = AIEditingLimits.load(defaults: defaults)
        self.expectedEmail = defaults.string(forKey: "aiEditing.expectedEmail") ?? "hechuan@climamind.ai"
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keeps/AIEditing", isDirectory: true)
        self.runtime = runtime ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("AIEditing", isDirectory: true)
        self.codeRuntime = runtime ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        self.usage = AIEditingUsageStore(root: self.root.appendingPathComponent("usage", isDirectory: true))
        self.logDirectory = self.root.appendingPathComponent("logs", isDirectory: true)
    }

    func prepare() async { await refresh() }

    func refresh() async {
        guard !isBusy else { return }
        errorMessage = nil
        do {
            try prepareDirectories()
            try checkRuntime()
            try readAccount()
            if accountEmail != nil { try requireAccount() }
            status = accountEmail == nil ? "请登录 Keeps 专属 Codex 账户" : "已登录 \(accountEmail!)"
        } catch { fail(error) }
    }

    func login() async {
        await perform("等待浏览器登录", includeProcessLog: false) {
            try self.prepareDirectories()
            try self.checkRuntime()
            self.connectionVerified = false
            self.loginURL = nil
            defer { self.loginURL = nil }
            let result = try await self.runner.run(executable: self.executable,
                arguments: ["login", "-c", "cli_auth_credentials_store=\"file\"", "-c", "forced_login_method=\"chatgpt\""],
                home: self.home, directory: self.root, timeout: 300) { text in
                    if let url = Self.authorizationURL(in: text) { self.loginURL = url }
                }
            // Login output contains OAuth state and is never written to disk.
            guard result.exitCode == 0 else { throw AIEditingFailure("登录未完成（退出码 \(result.exitCode)），请重试浏览器授权。") }
            try self.readAccount()
            try self.requireAccount()
            self.status = "已登录 \(self.accountEmail!)；请运行连接测试"
        }
    }

    func logout() async {
        await perform("正在退出 Keeps 专属账户", includeProcessLog: false) {
            self.connectionVerified = false
            try self.prepareDirectories()
            guard FileManager.default.isExecutableFile(atPath: self.executable.path) else {
                throw AIEditingFailure("缺少内置 Codex，无法执行退出登录。")
            }
            let result = try await self.runner.run(executable: self.executable,
                arguments: ["logout", "-c", "cli_auth_credentials_store=\"file\""],
                home: self.home, directory: self.root, timeout: 15)
            guard result.exitCode == 0 else { throw AIEditingFailure("退出登录失败（退出码 \(result.exitCode)）。") }
            self.accountEmail = nil
            self.status = "已退出 Keeps 专属账户"
        }
    }

    func testConnection() async {
        await perform("正在验证账户与模型连接") {
            self.connectionVerified = false
            try self.prepareDirectories(); try self.checkRuntime(); try self.readAccount(); try self.requireAccount()
            let job = try self.newJob("connection")
            let result = try await self.runTracked(runner: self.runner, job: job,
                arguments: self.execArguments(job: job) + ["-"],
                input: "Reply with exactly KEEPS_CONNECTION_OK. Do not use any tools.", timeout: 90)
            try self.writeLog(result, job: job)
            guard result.exitCode == 0 else { throw AIEditingFailure.process(result, job: job) }
            let reply = try String(contentsOf: job.appendingPathComponent("result.json"), encoding: .utf8)
            guard reply.trimmingCharacters(in: .whitespacesAndNewlines) == "KEEPS_CONNECTION_OK" else {
                throw AIEditingFailure("模型未返回预期连接确认。诊断日志：\(job.path)")
            }
            try self.readAccount(); try self.requireAccount()
            self.connectionVerified = true
            self.status = "连接验证通过：\(self.accountEmail!) · \(self.model)"
        }
    }

    func testFixedPhoto() async {
        await perform("正在使用内置公开样片验证 AI 调色") {
            try await self.runPhoto(Self.bundledSample(in: self.runtime))
        }
    }

    static func bundledSample(in runtime: URL) throws -> URL {
        let source = runtime.appendingPathComponent("sample.jpg")
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw AIEditingFailure("安装包缺少内置测试图，请重新安装 Keeps。")
        }
        return source
    }

    func testPhoto(_ source: URL) async {
        await perform("正在执行单张 AI 调色测试") { try await self.runPhoto(source) }
    }

    func validateEditingAccount() throws {
        try prepareDirectories(); try checkRuntime(); try readAccount(); try requireAccount()
    }

    func gradePhoto(_ source: URL, job: URL, context: AIGradeContext? = nil, priority: Int = Int.max, progress: ((String, Double, Double) -> Void)? = nil) async throws -> AIGradeResult {
        let id = UUID(), gradingRunner = AIEditingProcess()
        gradingRunners[id] = gradingRunner
        activeGrades = gradingRunners.count
        isBusy = true
        defer { gradingRunners[id] = nil; activeGrades = gradingRunners.count; isBusy = activeGrades > 0 }
        let result = job.appendingPathComponent("result.json")
        if FileManager.default.fileExists(atPath: result.path) {
            do { return try Self.gradeResult(in: job) }
            catch {
                // Preserve rejected model output for diagnosis, then allow an explicit retry.
                let rejected = job.appendingPathComponent("rejected-result-" + UUID().uuidString + ".json")
                try FileManager.default.moveItem(at: result, to: rejected)
            }
        }
        try validateEditingAccount()
        try await runPhoto(source, job: job, runner: gradingRunner, context: context, priority: priority, progress: progress)
        return try Self.gradeResult(in: job)
    }

    func stopForExit() {
        runner.stopForExit()
        for runner in gradingRunners.values { runner.stopForExit() }
    }

    private func runPhoto(_ source: URL, job requestedJob: URL? = nil, runner suppliedRunner: AIEditingProcess? = nil, context: AIGradeContext? = nil, priority: Int = Int.max, progress: ((String, Double, Double) -> Void)? = nil) async throws {
        let runner = suppliedRunner ?? self.runner
        if requestedJob == nil { self.resultPreview = nil; self.resultSummary = nil }
        try self.prepareDirectories(); try self.checkRuntime(); try self.readAccount(); try self.requireAccount()
        guard requestedJob != nil || self.connectionVerified else { throw AIEditingFailure("请先完成模型连接测试。") }
        let allowed = ["arw", "3fr", "dng", "cr2", "cr3", "nef", "raf", "orf", "rw2", "jpg", "jpeg", "heic", "heif"]
        guard allowed.contains(source.pathExtension.lowercased()) else { throw AIEditingFailure("当前支持 RAW、JPEG 和 HEIF 照片。") }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: source.path) else { throw AIEditingFailure("无法读取选中的照片。") }
        let job = try requestedJob ?? self.newJob("photo")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let skill = try Data(contentsOf: self.runtime.appendingPathComponent("SKILL.md"))
        let schema: [String: Any] = ["type": "object", "properties": [
            "status": ["type": "string", "enum": ["ready"]],
            "candidateID": ["type": "string", "minLength": 1], "reason": ["type": "string", "minLength": 1],
            "preferenceSuggestions": ["type": "array", "items": ["type": "string"], "maxItems": 3]],
            "required": ["status", "candidateID", "reason", "preferenceSuggestions"], "additionalProperties": false]
        let schemaURL = job.appendingPathComponent("result.schema.json")
        try JSONSerialization.data(withJSONObject: schema).write(to: schemaURL, options: .atomic)
        var arguments = self.execArguments(job: job) + ["--output-schema", schemaURL.path]
        var helperArguments = ["--darktable", self.codeRuntime.appendingPathComponent("darktable.app/Contents/MacOS/darktable-cli").path, "--source", source.path, "--job", job.appendingPathComponent("render").path]
        if let recipe = context?.baseRecipeJSON {
            let recipeURL = job.appendingPathComponent("base-recipe.json")
            try Data(recipe.utf8).write(to: recipeURL, options: .atomic)
            helperArguments += ["--base-recipe", recipeURL.path]
        }
        let version = try await runner.run(executable: self.executable, arguments: ["--version"], home: self.home, directory: job, timeout: 15)
        guard version.exitCode == 0 else { throw AIEditingFailure("无法检查内置 Codex 版本。") }
        progress?("等待初始预览准备", 0.05, 0.15)
        let preparationArguments = helperArguments + ["--prepare-preview"]
        // The parent owns this slot; the helper receives no KEEPS_RENDER_* environment.
        let preparation = try await withRenderSlot(priority: priority) {
            try await runner.run(executable: self.codeRuntime.appendingPathComponent("keeps-color-mcp"),
                arguments: preparationArguments, home: self.home, directory: job, timeout: 1200)
        }
        try writeLog(preparation, job: job, prefix: "prepare-" + UUID().uuidString + "-")
        guard preparation.exitCode == 0 else { throw AIEditingFailure.process(preparation, job: job) }
        progress?("初始预览已准备，开始 AI 调色", 0.15, 0.15)
        let settings: [String: Any] = [
            "mcp_servers.keeps_color.required": true,
            "mcp_servers.keeps_color.default_tools_approval_mode": "auto",
            "mcp_servers.keeps_color.command": self.codeRuntime.appendingPathComponent("keeps-color-mcp").path,
            "mcp_servers.keeps_color.args": helperArguments,
            "mcp_servers.keeps_color.env.KEEPS_RENDER_LIMIT": String(limits.renders),
            "mcp_servers.keeps_color.env.KEEPS_RENDER_PRIORITY": String(priority),
            "mcp_servers.keeps_color.env.KEEPS_RENDER_SLOTS": root.appendingPathComponent("render-slots").path,
            "mcp_servers.keeps_color.startup_timeout_sec": 7200,
            "mcp_servers.keeps_color.tool_timeout_sec": 7200]
        for key in settings.keys.sorted() { arguments += ["-c", key + "=" + (try Self.json(settings[key]!))] }
        let started = Date()
        var toolStarted: [String: Date] = [:]
        var toolSeconds = 0.0
        let renderStatus = job.appendingPathComponent("render/render-status.json")
        let renderMonitor = Task { @MainActor in
            var previous = ""
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: renderStatus),
                   let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let phase = state["phase"] as? String, let stamp = state["startedAt"] as? String {
                    let key = phase + stamp
                    if key != previous {
                        previous = key
                        if phase == "waiting" { progress?("等待本地渲染名额", 0.15, 0.15) }
                        if phase == "rendering" { progress?("darktable 正在渲染照片", 0.15, 0.85) }
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        defer { renderMonitor.cancel() }
        var runExitCode: Int32 = -1
        defer {
            let metadata: [String: Any] = ["toolSeconds": toolSeconds, "outsideToolsSeconds": max(0, Date().timeIntervalSince(started) - toolSeconds), "model": self.model, "codexVersion": version.output.trimmingCharacters(in: .whitespacesAndNewlines),
                "engineVersion": "5.6.2", "elapsedSeconds": Date().timeIntervalSince(started), "exitCode": runExitCode,
                "skillSHA256": SHA256.hash(data: skill).map { String(format: "%02x", $0) }.joined()]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: job.appendingPathComponent("run.json"), options: .atomic)
            }
        }
        let prompt = String(decoding: skill, as: UTF8.self) + """
        \nComplete this photo independently using only Keeps tools. Return the specified ready result after rendering one adjusted preview. Return reason in Chinese explaining why you chose these adjustments: the starting image, the user intent, and the purpose of the recipe changes. Describe intended effects, not verified outcomes; do not compare versions, rate the result, or recommend a winner.
        In this same result, return preferenceSuggestions: at most 3 concise Chinese suggestions summarizing reusable aesthetic preferences explicitly expressed by the user in instruction, batchInstruction, or the user requests in history. Extract only intent that applies across photos; exclude requests specific to this photo or batch, numeric exposure corrections, composition/local-mask instructions, and your own grading advice. Existing preferences are only a deduplication reference: do not extract them again or suggest equivalent preferences. If there is no explicit, sufficiently supported reusable user intent (including an automatic first grade without such requests), return []. These are candidates requiring user confirmation; do not claim they are saved or apply them as newly accepted preferences.
        """
        let contextualPrompt = prompt + (try context.map { "\nUser grading context (specific instruction takes precedence over batch and long-term preferences):\n" + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\nThe initial candidate already applies the exact base recipe to the original source. Iterate from its candidate ID; do not approximate or reset existing adjustments." } ?? "")
        var steps = AIEditingSteps()
        let result = try await self.runTracked(runner: runner, job: job, arguments: arguments + ["-"],
            input: contextualPrompt, timeout: 14400, onEvent: { line in
                if let data = line.data(using: .utf8),
                   let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let item = event["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
                   let id = item["id"] as? String {
                    if event["type"] as? String == "item.started" { toolStarted[id] = Date() }
                    if event["type"] as? String == "item.completed", let start = toolStarted.removeValue(forKey: id) {
                        toolSeconds += Date().timeIntervalSince(start)
                    }
                }
                if let step = steps.consume(line) { progress?(step.title, step.floor, step.ceiling) }
            })
        try self.writeLog(result, job: job)
        runExitCode = result.exitCode
        guard result.exitCode == 0 else { throw AIEditingFailure.process(result, job: job) }
        try self.readAccount(); try self.requireAccount()
        let validated = try Self.validateResult(in: job, requiresAdjustment: true)
        if requestedJob == nil {
            self.resultPreview = validated.preview
            self.resultSummary = validated.reason
            self.status = "调色预览已生成；结果保存在本机，等待你选择"
        }
    }

    func cancel() {
        runner.cancel()
        for runner in gradingRunners.values { runner.cancel() }
    }

    func withRenderSlot<T: Sendable>(priority: Int = Int.max, _ operation: @Sendable () async throws -> T) async throws -> T {
        try await RenderSlots.withSlot(directory: root.appendingPathComponent("render-slots"),
                                       limit: limits.bounded.renders, priority: priority, operation: operation)
    }

    private func runTracked(runner: AIEditingProcess, job: URL, arguments: [String], input: String,
                            timeout: TimeInterval, onEvent: ((String) -> Void)? = nil) async throws -> AIEditingProcess.Result {
        let attempt = try usage.begin(model: model, account: accountEmail, job: job)
        let events = job.appendingPathComponent("events-\(attempt.uuidString).jsonl")
        try Data().write(to: events, options: .atomic)
        let handle = try FileHandle(forWritingTo: events)
        defer { try? handle.close() }
        var lineIndex = 0
        var recordingError: Error?
        do {
            let result = try await runner.run(executable: executable, arguments: arguments, home: home,
                directory: job, input: input, timeout: timeout, onEvent: { line in
                    defer { lineIndex += 1 }
                    do {
                        try handle.write(contentsOf: Data((Self.redacted(line) + "\n").utf8))
                        try self.usage.consume(line, attemptID: attempt, eventIndex: lineIndex)
                    } catch { recordingError = error; runner.cancel() }
                    onEvent?(line)
                })
            if let recordingError { throw recordingError }
            try usage.finish(attemptID: attempt, success: result.exitCode == 0)
            return result
        } catch {
            do { try usage.finish(attemptID: attempt, success: false) }
            catch { usageError = "用量记录无法保存：" + String(reflecting: error) }
            let original = recordingError ?? error
            let trace = Self.redacted(String(reflecting: original) + "\n" + runner.lastErrors)
            do { try Data(trace.utf8).write(to: job.appendingPathComponent("failure-\(attempt.uuidString).log"), options: .atomic) }
            catch { usageError = "诊断日志无法保存：" + String(reflecting: error) }
            throw original
        }
    }

    private func perform(_ message: String, includeProcessLog: Bool = true, operation: () async throws -> Void) async {
        guard !isBusy, !batchActive else { return }
        isBusy = true; status = message; errorMessage = nil
        defer { isBusy = false }
        do { try await operation() } catch {
            let trace = String(reflecting: error) + (includeProcessLog ? "\n" + runner.lastErrors : "")
            if let data = Self.redacted(trace).data(using: .utf8) {
                try? data.write(to: logDirectory.appendingPathComponent("failure-\(UUID().uuidString).log"), options: .atomic)
            }
            fail(error)
        }
    }
    private func fail(_ error: Error) { errorMessage = AIEditingFailure.userMessage(error); status = "需要处理" }
    private func prepareDirectories() throws {
        for directory in [root, home, logDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("cli_auth_credentials_store = \"file\"\nforced_login_method = \"chatgpt\"\n".utf8)
            .write(to: home.appendingPathComponent("config.toml"), options: .atomic)
    }
    private func checkRuntime() throws {
        runtimeReady = false
        for relative in ["codex", "codex-code-mode-host", "keeps-color-mcp", "darktable.app/Contents/MacOS/darktable-cli"] {
            guard FileManager.default.isExecutableFile(atPath: codeRuntime.appendingPathComponent(relative).path) else {
                throw AIEditingFailure("当前应用缺少内置 AI 修图组件：\(relative)。请安装包含 AI 修图运行时的 Keeps。")
            }
        }
        guard FileManager.default.isReadableFile(atPath: runtime.appendingPathComponent("SKILL.md").path) else {
            throw AIEditingFailure("当前应用缺少内置 AI 调色 Skill。")
        }
        runtimeReady = true
    }
    private func readAccount() throws {
        let auth = home.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: auth.path) else { accountEmail = nil; connectionVerified = false; return }
        let email = try Self.emailFromAuth(Data(contentsOf: auth))
        if accountEmail != email { connectionVerified = false }
        accountEmail = email
    }
    private func requireAccount() throws {
        guard let accountEmail else { throw AIEditingFailure("请先登录 Keeps 专属 Codex 账户。") }
        try Self.validateAccount(actual: accountEmail, expected: expectedEmail)
    }
    private func newJob(_ kind: String) throws -> URL {
        let job = logDirectory.appendingPathComponent("\(kind)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return job
    }
    private func execArguments(job: URL) -> [String] {
        var arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json", "-m", model,
            "-s", "read-only", "-C", job.path, "-o", job.appendingPathComponent("result.json").path]
        for feature in ["shell_tool", "unified_exec", "apps", "hooks", "plugins", "remote_plugin", "skill_search"] {
            arguments += ["--disable", feature]
        }
        arguments += ["--enable", "skip_host_skill_discovery"]
        for setting in ["cli_auth_credentials_store=\"file\"", "forced_login_method=\"chatgpt\"", "model_reasoning_effort=\"high\"", "web_search=\"disabled\"", "project_doc_max_bytes=0"] {
            arguments += ["-c", setting]
        }
        return arguments
    }
    private func writeLog(_ result: AIEditingProcess.Result, job: URL, prefix: String = "") throws {
        try Data(Self.redacted(result.errors).utf8).write(to: job.appendingPathComponent(prefix + "stderr.log"), options: .atomic)
        // Keep protocol events for diagnosis, without embedded image data or credentials.
        let lines = result.output.split(separator: "\n").map { Self.redacted(String($0)) }
        try Data(lines.joined(separator: "\n").utf8).write(to: job.appendingPathComponent(prefix + "events.jsonl"), options: .atomic)
    }
    // Codex parses overrides as TOML, which does not accept JSON escaped slashes.
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func validateAccount(actual: String, expected: String) throws {
        let target = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target.contains("@"), actual.caseInsensitiveCompare(target) == .orderedSame else {
            throw AIEditingFailure("当前登录为 \(actual)，与指定账户 \(target) 不一致。请退出并使用指定账户登录。")
        }
    }
    static func emailFromAuth(_ data: Data) throws -> String {
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (auth["OPENAI_API_KEY"] as? String ?? "").isEmpty,
              let tokens = auth["tokens"] as? [String: Any], let token = tokens["id_token"] as? String else {
            throw AIEditingFailure("专属账户凭证无效，请重新登录。")
        }
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else { throw AIEditingFailure("账户身份信息无效，请重新登录。") }
        var encoded = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded), let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = claims["email"] as? String, email.contains("@") else {
            throw AIEditingFailure("无法识别登录账户邮箱，请重新登录。")
        }
        return email
    }
    static func authorizationURL(in text: String) -> URL? {
        let pattern = #"https://auth\.openai\.com/[^\s<>\"]+"#
        guard let range = text.range(of: pattern, options: .regularExpression), let url = URL(string: String(text[range])) else { return nil }
        return url
    }
    static func redacted(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"https://auth\.openai\.com/[^\s\"]+"#, with: "[authorization URL omitted]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, with: "[token omitted]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\"data\"\s*:\s*\"[A-Za-z0-9+/=]{256,}\""#, with: "\"data\":\"[image omitted]\"", options: .regularExpression)
        return result
    }
    static func gradeResult(in job: URL) throws -> AIGradeResult {
        let checked = try validateResult(in: job)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: job.appendingPathComponent("result.json"))) as! [String: Any]
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: job.appendingPathComponent("render/candidates.json"))) as! [String: Any]
        let suggestions = result["preferenceSuggestions"] as? [String]
        guard let id = result["candidateID"] as? String,
              let candidates = state["candidates"] as? [[String: Any]],
              let encoded = candidates.first(where: { $0["id"] as? String == id })?["recipe"] as? String,
              let recipe = Data(base64Encoded: encoded),
              (try JSONSerialization.jsonObject(with: recipe)) is [String: Any] else {
            throw AIEditingFailure("调色配方缺失，无法无损保存。")
        }
        guard checked.selected else {
            return AIGradeResult(status: result["status"] as! String, reason: checked.reason,
                recipeJSON: String(decoding: recipe, as: UTF8.self), timing: AIGradeTiming.read(job),
                preview: checked.preview, originalPreview: checked.originalPreview, preferenceSuggestions: suggestions)
        }
        let selection = try JSONSerialization.jsonObject(with: Data(contentsOf: job.appendingPathComponent("render/selection.json"))) as! [String: Any]
        guard let full = selection["fullSize"] as? String else { throw AIEditingFailure("完整调色结果缺失。") }
        let fullURL = URL(fileURLWithPath: full)
        let xmpURL = fullURL.deletingPathExtension().appendingPathExtension("xmp")
        return AIGradeResult(status: "selected", reason: checked.reason, fullSize: fullURL,
            recipeJSON: String(decoding: recipe, as: UTF8.self), xmp: try String(contentsOf: xmpURL, encoding: .utf8), timing: AIGradeTiming.read(job), preview: checked.preview, originalPreview: checked.originalPreview, preferenceSuggestions: suggestions)
    }

    func completeReviewResult(_ result: AIGradeResult, source: URL, priority: Int = Int.max) async throws -> AIGradeResult {
        guard result.isSelectable, let preview = result.preview else { throw AIEditingFailure("候选预览或配方缺失。") }
        let job = preview.deletingLastPathComponent().deletingLastPathComponent()
        let recovered = try Self.gradeResult(in: job)
        guard recovered.preview == preview, recovered.recipeJSON == result.recipeJSON else {
            throw AIEditingFailure("候选配方与本机记录不一致，无法发布。")
        }
        let output = try JSONSerialization.jsonObject(with: Data(contentsOf: job.appendingPathComponent("result.json"))) as! [String: Any]
        guard let candidateID = output["candidateID"] as? String else { throw AIEditingFailure("候选身份缺失。") }
        let process = AIEditingProcess(), id = UUID()
        gradingRunners[id] = process
        defer { gradingRunners[id] = nil }
        // This direct helper launch has no KEEPS_RENDER_* environment; the parent owns its slot.
        let execution = try await withRenderSlot(priority: priority) {
            try await process.run(executable: self.codeRuntime.appendingPathComponent("keeps-color-mcp"),
                arguments: ["--darktable", self.codeRuntime.appendingPathComponent("darktable.app/Contents/MacOS/darktable-cli").path,
                            "--source", source.path, "--job", job.appendingPathComponent("render").path,
                            "--select-candidate", candidateID], home: self.home, directory: job, timeout: 1200)
        }
        try writeLog(execution, job: job, prefix: "manual-export-" + id.uuidString + "-")
        guard execution.exitCode == 0 else { throw AIEditingFailure.process(execution, job: job) }
        let selection = try JSONSerialization.jsonObject(with: Data(contentsOf: job.appendingPathComponent("render/selection.json"))) as! [String: Any]
        guard selection["candidateID"] as? String == candidateID, let full = selection["fullSize"] as? String else {
            throw AIEditingFailure("完整调色结果与所选候选不一致。")
        }
        let fullURL = URL(fileURLWithPath: full).resolvingSymlinksInPath()
        guard fullURL.path.hasPrefix(job.appendingPathComponent("render").resolvingSymlinksInPath().path + "/"),
              FileManager.default.isReadableFile(atPath: fullURL.path) else { throw AIEditingFailure("完整调色结果缺失或位于任务目录之外。") }
        var completed = result
        completed.fullSize = fullURL
        completed.xmp = try String(contentsOf: fullURL.deletingPathExtension().appendingPathExtension("xmp"), encoding: .utf8)
        return completed
    }

    struct ValidatedResult { let selected: Bool; let preview: URL?; let originalPreview: URL?; let reason: String }
    static func validateResult(in job: URL, requiresAdjustment: Bool = false) throws -> ValidatedResult {
        func object(_ path: String) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: job.appendingPathComponent(path))) as? [String: Any] else {
                throw AIEditingFailure("调色结果格式无效。")
            }
            return value
        }
        let result = try object("result.json"), store = try object("render/candidates.json")
        if let id = result["candidateID"] as? String, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let reason = result["reason"] as? String, !reason.isEmpty {
            throw AIEditingFailure("AI 未生成候选：" + reason)
        }
        guard let status = result["status"] as? String, ["ready", "selected", "unchanged", "needs_review"].contains(status),
              let id = result["candidateID"] as? String,
              let candidates = store["candidates"] as? [[String: Any]], candidates.contains(where: { $0["id"] as? String == id }) else {
            throw AIEditingFailure("AI 返回了未知候选或无效状态，结果未被接受。")
        }
        let reason = result["reason"] as? String ?? ""
        if requiresAdjustment {
            let candidate = candidates.first { $0["id"] as? String == id }!
            let starting = candidates.filter { ["baseline", "iteration-base"].contains($0["operationID"] as? String ?? "") }
            guard status == "ready", let recipe = candidate["recipe"] as? String,
                  !starting.contains(where: { $0["id"] as? String == id || $0["recipe"] as? String == recipe }) else {
                throw AIEditingFailure("AI 未生成有实际调整的候选版本，请重试调色。")
            }
        }
        let directory = job.appendingPathComponent("render").resolvingSymlinksInPath().path + "/"
        func verifiedPreview(_ candidateID: String) throws -> URL {
            let url = job.appendingPathComponent("render/" + candidateID + "-preview.jpg").resolvingSymlinksInPath()
            guard url.path.hasPrefix(directory), FileManager.default.isReadableFile(atPath: url.path) else {
                throw AIEditingFailure("候选预览缺失或位于任务目录之外。")
            }
            return url
        }
        let baseline = candidates.first { $0["operationID"] as? String == "baseline" }?["id"] as? String
        let original = try baseline.map { try verifiedPreview($0) }
        guard status == "selected" else {
            return ValidatedResult(selected: false, preview: try verifiedPreview(id), originalPreview: original, reason: reason)
        }
        let selection = try object("render/selection.json")
        guard selection["candidateID"] as? String == id, let preview = selection["preview"] as? String, let full = selection["fullSize"] as? String else {
            throw AIEditingFailure("AI 选择与已渲染结果不一致。")
        }
        for path in [preview, full] {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(directory), FileManager.default.isReadableFile(atPath: url.path) else {
                throw AIEditingFailure("候选图像缺失或位于任务目录之外。")
            }
        }
        return ValidatedResult(selected: true, preview: URL(fileURLWithPath: preview), originalPreview: original, reason: reason)
    }
}

struct AIGradeContext: Codable, Sendable {
    var preferences: String = ""
    var batchInstruction: String = ""
    var instruction: String = ""
    var baseRecipeJSON: String? = nil
    var history: [String] = []
}

struct AIGradeResult: Codable, Sendable {
    var isSelectable: Bool { status == "selected" || (["ready", "needs_review"].contains(status) && recipeJSON != nil) }
    var status: String
    var reason: String
    var fullSize: URL? = nil
    var recipeJSON: String? = nil
    var xmp: String? = nil
    var timing: AIGradeTiming? = nil
    var preview: URL? = nil
    var originalPreview: URL? = nil
    var preferenceSuggestions: [String]? = nil
}

struct AIGradeTiming: Codable, Sendable {
    let sessionSeconds: Double
    let renderSeconds: Double
    let renderQueueSeconds: Double

    static func read(_ job: URL) -> Self? {
        guard let data = try? Data(contentsOf: job.appendingPathComponent("run.json")),
              let run = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elapsed = run["elapsedSeconds"] as? Double else { return nil }
        let timingData = try? Data(contentsOf: job.appendingPathComponent("render/render-timings.json"))
        let document = timingData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let records = document?["records"] as? [[String: Any]] ?? []
        return Self(sessionSeconds: elapsed,
                    renderSeconds: records.reduce(0) { $0 + ($1["executionSeconds"] as? Double ?? 0) },
                    renderQueueSeconds: records.reduce(0) { $0 + ($1["queuedSeconds"] as? Double ?? 0) })
    }
}


struct AIEditingSteps {
    private var adjustments = 0
    mutating func consume(_ line: String) -> (title: String, floor: Double, ceiling: Double)? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["type"] as? String else { return nil }
        if kind == "turn.started" { return ("AI 正在观察照片", 0.17, 0.28) }
        guard kind == "item.started", let item = event["item"] as? [String: Any],
              item["type"] as? String == "mcp_tool_call", item["server"] as? String == "keeps_color",
              let tool = item["tool"] as? String else { return nil }
        switch tool {
        case "inspect_photo": return ("生成初始预览，分析曝光与色彩", 0.20, 0.32)
        case "set_adjustments":
            adjustments += 1
            let floor = 0.34 + Double(min(adjustments - 1, 3)) * 0.09
            return ("第 \(adjustments) 轮：调整曝光与色彩", floor, min(0.77, floor + 0.09))
        case "render_preview": return ("第 \(max(1, adjustments)) 轮：渲染调色预览", 0.42, 0.74)
        case "preview_region": return ("观察调整前照片细节", 0.25, 0.34)
        default: return nil
        }
    }
}
