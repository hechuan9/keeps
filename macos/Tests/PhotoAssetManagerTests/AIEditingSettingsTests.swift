import Foundation
import Testing
import KeepsAPI
import CryptoKit
@testable import PhotoAssetManager

@MainActor struct AIEditingSettingsTests {
    @Test(arguments: [
        ("Error loading config.toml: invalid type: string, expected a sequence", "配置有误"),
        ("401 Unauthorized: token expired", "登录已失效"),
        ("insufficient_quota", "额度已用完"),
        ("model_not_found", "无法使用所选 AI 模型"),
        ("429 too many requests", "请求过于频繁"),
        ("stream disconnected", "连接 AI 服务"),
        ("mcp startup failed", "本机调色工具"),
        ("unexpected crash", "暂时无法确定原因")
    ])
    func commonFailuresExplainRecovery(diagnostic: String, expected: String) {
        let job = URL(fileURLWithPath: "/tmp/diagnostics")
        let failure = AIEditingFailure.process(.init(exitCode: 1, output: "", errors: diagnostic), job: job)
        #expect(failure.localizedDescription.contains(expected))
        #expect(failure.logDirectory == job)
        #expect(!failure.localizedDescription.contains("AIEditingFailure("))
    }

    @Test func onlyExplicitAITransientFailuresRetry() {
        let job = URL(fileURLWithPath: "/tmp/diagnostics")
        func failure(_ text: String) -> AIEditingFailure {
            AIEditingFailure.process(.init(exitCode: 1, output: "", errors: text), job: job)
        }
        #expect(failure("HTTP 429 Too Many Requests").retryable)
        #expect(failure("stream disconnected").retryable)
        #expect(!failure("429 insufficient_quota").retryable)
        #expect(!failure("2026-10-08T12:00:00.429Z unexpected crash").retryable)
    }

    @Test func realToolEventsDescribeInternalSteps() {
        var steps = AIEditingSteps()
        #expect(steps.consume("not json") == nil)
        func event(_ tool: String) -> String { "{\"type\":\"item.started\",\"item\":{\"type\":\"mcp_tool_call\",\"server\":\"keeps_color\",\"tool\":\"" + tool + "\"}}" }
        #expect(steps.consume(event("inspect_photo"))?.title.contains("初始预览") == true)
        #expect(steps.consume(event("set_adjustments"))?.title.contains("第 1 轮") == true)
        #expect(steps.consume(event("set_adjustments"))?.title.contains("第 2 轮") == true)
        #expect(steps.consume(event("compare_candidates")) == nil)
        #expect(steps.consume(event("select_candidate")) == nil)
    }

    @Test func streamedEventsArriveBeforeProcessExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var lines: [String] = []
        var deliveredWhileRunning = false
        _ = try await AIEditingProcess().run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'first'; sleep 0.1; printf '\\nsecond\\n'; while [ ! -f acknowledged ]; do sleep 0.05; done; touch finished"], home: root, directory: root,
            timeout: 5, onEvent: { line in
                lines.append(line)
                deliveredWhileRunning = deliveredWhileRunning || !FileManager.default.fileExists(atPath: root.appendingPathComponent("finished").path)
                if line == "second" {
                    do { try Data().write(to: root.appendingPathComponent("acknowledged")) }
                    catch { Issue.record("Could not acknowledge streamed event: \(error)") }
                }
            })
        #expect(lines == ["first", "second"])
        #expect(deliveredWhileRunning)
    }

    @Test(arguments: [false, true])
    func cancellationAndTimeoutDrainFinalUsage(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let event = #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}"#
        let script = "trap 'printf \"%s\\n\" \"" + event.replacingOccurrences(of: "\"", with: "\\\"") + "\"; exit 0' TERM; printf 'ready\\n'; while :; do :; done"
        let process = AIEditingProcess()
        let usage = AIEditingUsageStore(root: root)
        let attempt = try usage.begin(model: "gpt-6-luna", account: nil, job: root)
        var eventIndex = 0
        var receivedReady = false
        await #expect(throws: (any Error).self) {
            _ = try await process.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                home: root, directory: root, timeout: cancel ? 5 : 0.3, onEvent: { line in
                    defer { eventIndex += 1 }
                    do { try usage.consume(line, attemptID: attempt, eventIndex: eventIndex) }
                    catch { Issue.record("Could not record final usage: \(error)") }
                    if line == "ready" {
                        receivedReady = true
                        if cancel { process.cancel() }
                    }
                })
        }
        try usage.finish(attemptID: attempt, success: false)
        #expect(receivedReady)
        #expect(usage.attempts.first?.usage?.total == 110)
        #expect(AIEditingUsageStore(root: root).attempts.first?.usage?.total == 110)
    }

    @Test(arguments: [false, true])
    func completedResultResumesWithoutAccountOrRuntime(withSuggestions: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job"), render = job.appendingPathComponent("render")
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        func write(_ value: [String: Any], _ file: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: job.appendingPathComponent(file))
        }
        let preview = render.appendingPathComponent("preview.jpg"), full = render.appendingPathComponent("full.jpg")
        try Data([1]).write(to: preview); try Data([1]).write(to: full)
        try Data("<xmp/>".utf8).write(to: full.deletingPathExtension().appendingPathExtension("xmp"))
        var output: [String: Any] = ["status": "selected", "candidateID": "one", "reason": "已完成"]
        if withSuggestions { output["preferenceSuggestions"] = ["偏好自然柔和的肤色"] }
        try write(output, "result.json")
        try write(["candidates": [["id": "one", "recipe": Data("{}".utf8).base64EncodedString()]]], "render/candidates.json")
        try write(["candidateID": "one", "preview": preview.path, "fullSize": full.path], "render/selection.json")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AIEditingSettingsStore(root: root.appendingPathComponent("no-account"),
            runtime: root.appendingPathComponent("no-runtime"), defaults: defaults)
        let result = try await store.gradePhoto(root.appendingPathComponent("unavailable-source.arw"), job: job)
        #expect(result.status == "selected")
        #expect(result.fullSize == full)
        #expect(result.recipeJSON == "{}")
        #expect(result.xmp == "<xmp/>")
        #expect(result.preferenceSuggestions == (withSuggestions ? ["偏好自然柔和的肤色"] : nil))
        #expect(store.usage.attempts.isEmpty)
        #expect(!store.isBusy && store.activeGrades == 0)
    }

    @Test func oldGradeDraftDecodesWithoutPreferenceSuggestions() throws {
        let old = Data(#"{"status":"selected","reason":"保留氛围"}"#.utf8)
        let result = try JSONDecoder().decode(AIGradeResult.self, from: old)
        #expect(result.preferenceSuggestions == nil)
        #expect(result.status == "selected")
    }

    @Test func nasFailureDoesNotExposeRawResponse() {
        let message = AIEditingFailure.userMessage(KeepsAPIError.http(409, "internal raw response"))
        #expect(message.contains("未覆盖"))
        #expect(!message.contains("internal raw response"))
        #expect(AIEditingFailure.userMessage(URLError(.notConnectedToInternet)).contains("NAS"))
    }

    @Test func configurationPathsAreValidForCodex() throws {
        let arguments = ["--source", "/tmp/test folder/照片.ARW", "--job", "/tmp/job"]
        let encoded = try AIEditingSettingsStore.json(arguments)
        #expect(!encoded.contains("\\/"))
        #expect(try JSONDecoder().decode([String].self, from: Data(encoded.utf8)) == arguments)
        if let binary = ProcessInfo.processInfo.environment["KEEPS_TEST_CODEX"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: binary)
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            process.environment = AIEditingProcess.environment(home: home, ambient: ProcessInfo.processInfo.environment)
            process.arguments = ["features", "list", "-c", "mcp_servers.keeps_color.command=\"/tmp/helper\"", "-c", "mcp_servers.keeps_color.args=" + encoded]
            process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    @Test func bundledSampleIsLocalAndMissingResourceFails() throws {
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: runtime) }
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try AIEditingSettingsStore.bundledSample(in: runtime) }
        let sample = runtime.appendingPathComponent("sample.jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: sample)
        #expect(try AIEditingSettingsStore.bundledSample(in: runtime) == sample)
    }

    @Test func environmentDoesNotInheritHostAuthentication() {
        let home = URL(fileURLWithPath: "/tmp/keeps-only")
        let env = AIEditingProcess.environment(home: home, ambient: [
            "HOME": "/Users/test", "CODEX_HOME": "/host/codex", "OPENAI_API_KEY": "secret",
            "CODEX_ACCESS_TOKEN": "secret", "OPENAI_BASE_URL": "https://unexpected.invalid", "PATH": "/host/bin"])
        #expect(env["CODEX_HOME"] == home.path)
        #expect(env["HOME"] == "/Users/test")
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["CODEX_ACCESS_TOKEN"] == nil)
        #expect(env["OPENAI_BASE_URL"] == nil)
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func requiresMatchingChatGPTAccount() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": "hechuan@climamind.ai"])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let auth: [String: Any] = ["tokens": ["id_token": "header.\(encoded).signature"]]
        #expect(try AIEditingSettingsStore.emailFromAuth(JSONSerialization.data(withJSONObject: auth)) == "hechuan@climamind.ai")
        try AIEditingSettingsStore.validateAccount(actual: "hechuan@climamind.ai", expected: " HECHUAN@climamind.ai ")
        #expect(throws: (any Error).self) { try AIEditingSettingsStore.validateAccount(actual: "other@example.com", expected: "hechuan@climamind.ai") }
        var mixed = auth; mixed["OPENAI_API_KEY"] = "not-allowed"
        #expect(throws: (any Error).self) { try AIEditingSettingsStore.emailFromAuth(JSONSerialization.data(withJSONObject: mixed)) }
    }

    @Test func changingExpectedAccountInvalidatesConnection() {
        let suite = "KeepsAI-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIEditingSettingsStore(defaults: defaults)
        store.expectedEmail = "different@example.com"
        #expect(!store.connectionVerified)
        #expect(defaults.string(forKey: "aiEditing.expectedEmail") == "different@example.com")
    }

    @Test func resultMustMatchRenderedCandidateAndStayInJob() throws {
        let job = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-result-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: job) }
        let render = job.appendingPathComponent("render")
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        func write(_ value: [String: Any], _ file: String) throws { try JSONSerialization.data(withJSONObject: value).write(to: job.appendingPathComponent(file)) }
        try write(["status": "selected", "candidateID": "one", "reason": "测试"], "result.json")
        try write(["candidates": [["id": "one"]]], "render/candidates.json")
        let preview = render.appendingPathComponent("one-preview.jpg"), full = render.appendingPathComponent("one-full.jpg")
        try Data([1]).write(to: preview); try Data([1]).write(to: full)
        try write(["candidateID": "one", "preview": preview.path, "fullSize": full.path], "render/selection.json")
        #expect(try AIEditingSettingsStore.validateResult(in: job).selected)
        try write(["candidateID": "other", "preview": preview.path, "fullSize": full.path], "render/selection.json")
        #expect(throws: (any Error).self) { try AIEditingSettingsStore.validateResult(in: job) }
        try write(["candidateID": "one", "preview": preview.path, "fullSize": "/etc/hosts"], "render/selection.json")
        #expect(throws: (any Error).self) { try AIEditingSettingsStore.validateResult(in: job) }
    }

    @Test func missingCandidatePreservesToolFailureReason() throws {
        let job = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: job) }
        try FileManager.default.createDirectory(at: job.appendingPathComponent("render"), withIntermediateDirectories: true)
        try Data(#"{"candidates":[]}"#.utf8).write(to: job.appendingPathComponent("render/candidates.json"))
        try Data(#"{"status":"needs_review","candidateID":"","reason":"inspect_photo 无响应"}"#.utf8).write(to: job.appendingPathComponent("result.json"))
        do {
            _ = try AIEditingSettingsStore.validateResult(in: job)
            Issue.record("Expected missing candidate failure")
        } catch {
            #expect(String(reflecting: error).contains("inspect_photo 无响应"))
        }
    }

    @Test func freshGradingRequiresAdjustedCandidate() throws {
        let job = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: job) }
        let render = job.appendingPathComponent("render")
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        let candidates: [[String: String]] = [
            ["id": "raw", "operationID": "baseline", "recipe": "original"],
            ["id": "base", "operationID": "iteration-base", "recipe": "base"],
            ["id": "copy", "recipe": "base"],
            ["id": "adjusted", "recipe": "new"]]
        try JSONSerialization.data(withJSONObject: ["candidates": candidates]).write(to: render.appendingPathComponent("candidates.json"))
        for id in ["raw", "base", "copy", "adjusted"] {
            try Data([1]).write(to: render.appendingPathComponent(id + "-preview.jpg"))
        }
        for (status, id) in [("ready", "raw"), ("ready", "base"), ("ready", "copy"), ("unchanged", "adjusted"), ("ready", "adjusted")] {
            try JSONSerialization.data(withJSONObject: ["status": status, "candidateID": id]).write(to: job.appendingPathComponent("result.json"))
            if status == "ready" && id == "adjusted" {
                #expect(try AIEditingSettingsStore.validateResult(in: job, requiresAdjustment: true).preview != nil)
            } else {
                #expect(throws: (any Error).self) { try AIEditingSettingsStore.validateResult(in: job, requiresAdjustment: true) }
            }
        }
    }

    @Test func unselectedResultsRetainVerifiedComparisonPreviews() throws {
        let job = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-comparison-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: job) }
        let render = job.appendingPathComponent("render")
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        func write(_ value: [String: Any], _ path: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: job.appendingPathComponent(path))
        }
        try write(["candidates": [["id": "raw", "operationID": "baseline"], ["id": "candidate", "recipe": Data("{}".utf8).base64EncodedString()]]], "render/candidates.json")
        let original = render.appendingPathComponent("raw-preview.jpg")
        let preview = render.appendingPathComponent("candidate-preview.jpg")
        try Data([1]).write(to: original)
        try Data([2]).write(to: preview)
        for status in ["unchanged", "needs_review"] {
            try write(["status": status, "candidateID": "candidate", "reason": "保留氛围"], "result.json")
            let result = try AIEditingSettingsStore.gradeResult(in: job)
            #expect(result.preview?.resolvingSymlinksInPath() == preview.resolvingSymlinksInPath())
            #expect(result.originalPreview?.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
            #expect(result.fullSize == nil)
            #expect(result.recipeJSON == "{}")
            #expect(result.isSelectable == (status == "needs_review"))
            #expect(result.preferenceSuggestions == nil)
        }
        try FileManager.default.removeItem(at: preview)
        #expect(throws: (any Error).self) { try AIEditingSettingsStore.gradeResult(in: job) }
    }

    @Test(arguments: ["ready", "needs_review"]) func humanReviewedCandidateExportsWithoutAIAccountOrAnotherDecision(status: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-human-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job"), render = job.appendingPathComponent("render")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        func write(_ value: [String: Any], _ path: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: job.appendingPathComponent(path))
        }
        var output: [String: Any] = ["status": status, "candidateID": "candidate", "preferenceSuggestions": ["偏好柔和的高光过渡"]]
        output["reason"] = status == "ready" ? "提亮人物以呼应用户要求，保留窗外高光" : "检查靠垫溢出"
        try write(output, "result.json")
        try write(["candidates": [["id": "candidate", "recipe": Data("{}".utf8).base64EncodedString()]]], "render/candidates.json")
        let preview = render.appendingPathComponent("candidate-preview.jpg"), full = render.appendingPathComponent("full.jpg")
        try Data([1]).write(to: preview); try Data([2]).write(to: full)
        try Data("<xmp/>".utf8).write(to: full.deletingPathExtension().appendingPathExtension("xmp"))
        try write(["candidateID": "candidate", "preview": preview.path, "fullSize": full.path], "render/expected-selection.json")
        try Data("original events".utf8).write(to: job.appendingPathComponent("events.jsonl"))
        try Data("original stderr".utf8).write(to: job.appendingPathComponent("stderr.log"))
        let helper = runtime.appendingPathComponent("keeps-color-mcp")
        let script = "#!/bin/sh\n[ \"$7\" = --select-candidate ] && [ \"$8\" = candidate ] || exit 9\n[ -z \"$KEEPS_RENDER_LIMIT\" ] && [ -z \"$KEEPS_RENDER_SLOTS\" ] || exit 10\ncp render/expected-selection.json render/selection.json\n"
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let store = AIEditingSettingsStore(root: root.appendingPathComponent("no-account"), runtime: runtime,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.limits.renders = 1
        let reviewed = try AIEditingSettingsStore.gradeResult(in: job)
        #expect(reviewed.isSelectable)
        #expect(reviewed.fullSize == nil)
        if status == "ready" { #expect(reviewed.reason == "提亮人物以呼应用户要求，保留窗外高光") }
        let completed = try await store.completeReviewResult(reviewed, source: root.appendingPathComponent("source.arw"))
        #expect(completed.status == status)
        #expect(completed.reason == reviewed.reason)
        #expect(reviewed.preferenceSuggestions == ["偏好柔和的高光过渡"])
        #expect(completed.preferenceSuggestions == reviewed.preferenceSuggestions)
        #expect(completed.recipeJSON == reviewed.recipeJSON)
        #expect(completed.fullSize == full.resolvingSymlinksInPath())
        #expect(completed.xmp == "<xmp/>")
        #expect(try String(contentsOf: job.appendingPathComponent("events.jsonl"), encoding: .utf8) == "original events")
        #expect(try String(contentsOf: job.appendingPathComponent("stderr.log"), encoding: .utf8) == "original stderr")
        let exportLogs = try FileManager.default.contentsOfDirectory(atPath: job.path).filter { $0.hasPrefix("manual-export-") }
        #expect(exportLogs.count == 2)
        #expect(store.usage.attempts.isEmpty)
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: job.appendingPathComponent("result.json"))) as! [String: Any]
        #expect(original["status"] as? String == status)
    }

    @Test func missingOrDifferentAccountNeverStartsCodex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-auth-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let started = root.appendingPathComponent("started")
        for file in ["codex", "codex-code-mode-host", "keeps-color-mcp", "darktable.app/Contents/MacOS/darktable-cli"] {
            let url = runtime.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho started > '\(started.path)'\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try Data("test skill".utf8).write(to: runtime.appendingPathComponent("SKILL.md"))
        let suite = "KeepsAI-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIEditingSettingsStore(root: root, runtime: runtime, defaults: defaults)
        await store.prepare()
        #expect(store.runtimeReady)
        await store.testConnection()
        #expect(store.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: started.path))
        let payload = try JSONSerialization.data(withJSONObject: ["email": "wrong@example.com"]).base64EncodedString()
        let auth: [String: Any] = ["tokens": ["id_token": "header.\(payload).signature"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: root.appendingPathComponent("codex/auth.json"))
        await store.refresh()
        #expect(store.errorMessage?.contains("不一致") == true)
        await store.testConnection()
        #expect(!FileManager.default.fileExists(atPath: started.path))
        #expect(!store.connectionVerified)
    }

    @Test func authorizationURLStaysOutOfLogs() {
        let text = "Open https://auth.openai.com/oauth/authorize?state=secret&code_challenge=private\n"
        #expect(AIEditingSettingsStore.authorizationURL(in: text)?.host == "auth.openai.com")
        let redacted = AIEditingSettingsStore.redacted(text + " eyJabc.defghi.jklmnop")
        #expect(!redacted.contains("state=secret"))
        #expect(!redacted.contains("eyJabc"))
    }

    @Test func processTimeoutAndCancellationFinish() async throws {
        let directory = FileManager.default.temporaryDirectory
        let process = AIEditingProcess()
        await #expect(throws: (any Error).self) {
            _ = try await process.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], home: directory, directory: directory, timeout: 0.1)
        }
        let task = Task { try await process.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], home: directory, directory: directory, timeout: 60) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let result = try await process.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["finished"], home: directory, directory: directory, timeout: 5)
        #expect(result.output == "finished\n")
    }
}
