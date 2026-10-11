import AppKit
import SwiftUI

struct AIEditingSettingsView: View {
    @ObservedObject var store: AIEditingSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("AI 修图", systemImage: "wand.and.stars").font(.title2)
                    Text("AI 在线分析照片，调色由这台 Mac 执行。Keeps 使用独立登录，不使用本机其他 Codex 会话的账户。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                runtimeSection
                accountSection
                concurrencySection
                AIEditingUsageView(store: store.usage)
                verificationSection
                progressSection
                resultSection
            }
            .padding(24)
        }
        .frame(width: 620, height: 660)
        .task { await store.prepare() }
    }

    private var runtimeSection: some View {
        GroupBox {
            HStack {
                Label(store.runtimeReady ? "运行环境已就绪" : "准备修图运行环境", systemImage: store.runtimeReady ? "checkmark.circle" : "shippingbox")
                Spacer()
                Button("检查运行环境") { Task { await store.prepare() } }
                    .disabled(store.isBusy || store.batchActive)
            }.padding(8)
        } label: { Text("1. 运行环境") }
    }

    private var accountSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextField("修图账户邮箱", text: $store.expectedEmail)
                    .textFieldStyle(.roundedBorder)
                    .disabled(store.isBusy || store.batchActive)
                    .accessibilityIdentifier("ai-editing-email")
                Text("请在浏览器中使用此邮箱登录。账户核对通过后才能测试修图。")
                    .font(.caption).foregroundStyle(.secondary)
                if let email = store.accountEmail {
                    LabeledContent("当前登录", value: email).textSelection(.enabled)
                } else {
                    Text("尚未登录 Keeps 修图账户").foregroundStyle(.secondary)
                }
                HStack {
                    Button("登录修图账户") { Task { await store.login() } }
                        .disabled(store.isBusy || store.batchActive || !store.runtimeReady || store.expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ai-editing-login")
                    Button("刷新状态") { Task { await store.refresh() } }.disabled(store.isBusy || store.batchActive)
                    Spacer()
                    Button("退出登录") { Task { await store.logout() } }
                        .disabled(store.isBusy || store.batchActive || store.accountEmail == nil)
                }
                if let url = store.loginURL {
                    Button("在浏览器中继续登录") { NSWorkspace.shared.open(url) }
                        .accessibilityIdentifier("ai-editing-open-login")
                }
            }.padding(8)
        } label: { Text("2. 独立账户") }
    }

    private var verificationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("先确认 AI 连接可用，再使用固定样片完成试调色。原片保持不变，预览会发送给 AI 服务进行分析。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("测试 AI 连接") { Task { await store.testConnection() } }
                        .disabled(store.isBusy || store.batchActive || !store.runtimeReady || store.accountEmail == nil)
                        .accessibilityIdentifier("ai-editing-test-connection")
                    if store.connectionVerified {
                        Label("连接已验证", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    Spacer()
                }
                Text("内置公开风景样片（CC0），无需连接照片库。").font(.caption).foregroundStyle(.secondary)
                Button("使用内置样片验证") { Task { await store.testFixedPhoto() } }
                    .disabled(store.isBusy || store.batchActive || !store.connectionVerified)
                    .accessibilityIdentifier("ai-editing-test-photo")
            }.padding(8)
        } label: { Text("3. 验证与试修图") }
    }

    private var concurrencySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConcurrencyNumberField("同时处理照片", value: $store.limits.photos)
                ConcurrencyNumberField("AI 会话", value: $store.limits.ai)
                ConcurrencyNumberField("本地渲染", value: $store.limits.renders)
                ConcurrencyNumberField("下载", value: $store.limits.downloads)
                ConcurrencyNumberField("上传", value: $store.limits.uploads)
                Text("各项独立限制并发数量；本地渲染建议从 2 开始。修改在下一批调色生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
            .disabled(store.isBusy || store.batchActive)
        } label: { Text("并发处理") }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if store.isBusy { ProgressView().controlSize(.small) }
                Text(store.status).font(.callout).textSelection(.enabled)
                Spacer()
                if store.isBusy && !store.batchActive { Button("取消", action: store.cancel) }
            }
            if let error = store.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("ai-editing-error")
            }
            Button("打开运行日志") { NSWorkspace.shared.open(store.logDirectory) }
                .font(.callout)
        }
    }

    @ViewBuilder private var resultSection: some View {
        if store.resultPreview != nil || store.resultSummary != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("试修图结果").font(.headline)
                if let preview = store.resultPreview, let image = NSImage(contentsOf: preview) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                        .accessibilityLabel("AI 试修图预览")
                }
                if let summary = store.resultSummary { Text(summary).font(.callout).textSelection(.enabled) }
                if let preview = store.resultPreview {
                    Button("查看结果文件") { NSWorkspace.shared.activateFileViewerSelecting([preview]) }
                }
                Text("此结果仅保存在本机，不会发布到资料库。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}

private struct AIEditingUsageView: View {
    @ObservedObject var store: AIEditingUsageStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                let today = store.days.first { $0.id == AIEditingUsageStore.dayKey(Date()) }
                Text("今日：\(today?.tokens ?? 0) tokens · API 等价预估 \(money(today?.estimatedUSD ?? 0))")
                    .font(.headline)
                if let today, today.unknown > 0 {
                    Text("\(today.unknown) 次运行尚未报告用量，合计可能不完整。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("按 GPT-6 Luna Standard 短上下文价格估算，不代表 ChatGPT 账户账单。日志不提供逐请求上下文档位，长上下文实际等价费用可能更高。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("每百万 tokens：输入 $0.10、缓存输入 $0.01、缓存写入 $0.125、输出 $0.50。费率核对：2026-10-08；每次运行保留当时费率。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("查看官方 API 价格", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                if let error = store.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                DisclosureGroup("每日历史（按运行开始时本机日期）") {
                    if store.days.isEmpty { Text("尚无用量记录").foregroundStyle(.secondary) }
                    ForEach(store.days) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(day.id) · \(day.attempts.count) 次运行 · \(day.tokens) tokens · \(money(day.estimatedUSD))")
                            Text("普通输入 \(day.ordinaryInput) · 缓存输入 \(day.cachedInput) · 缓存写入 \(day.cacheWriteInput) · 输出 \(day.output)")
                                .font(.caption).foregroundStyle(.secondary)
                            if day.unknown > 0 { Text("\(day.unknown) 次尚未报告用量（运行中或中断），未计入合计。")
                                .font(.caption).foregroundStyle(.secondary) }
                            if day.unpriced > 0 { Text("\(day.unpriced) 次没有已核对费率，未计入费用。")
                                .font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                }
            }.padding(8)
        } label: { Text("用量与费用") }
    }

    private func money(_ dollars: Double) -> String { String(format: "$%.5f", dollars) }
}

private struct ConcurrencyNumberField: View {
    private let title: String
    @Binding private var value: Int
    @State private var text: String
    @FocusState private var focused: Bool

    init(_ title: String, value: Binding<Int>) {
        self.title = title
        self._value = value
        self._text = State(initialValue: String(value.wrappedValue))
    }

    private var validNumber: Int? {
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...20).contains(number) else { return nil }
        return number
    }

    var body: some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($focused)
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityHint("输入 1 到 20 的整数")
                .onChange(of: text) { _, _ in
                    if let number = validNumber { value = number }
                }
                .onSubmit { text = String(value) }
                .onChange(of: focused) { _, editing in
                    if !editing { text = String(value) }
                }
                .onChange(of: value) { _, number in
                    if !focused { text = String(number) }
                }
            Text(validNumber == nil ? "请输入 1–20 的整数" : "1–20")
                .font(.caption)
                .foregroundStyle(validNumber == nil ? Color.red : Color.secondary)
            Spacer()
        }
    }
}
