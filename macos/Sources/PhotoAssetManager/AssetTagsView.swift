import SwiftUI
import KeepsAPI

@MainActor private final class TagGenerationProgress: ObservableObject {
    @Published var message: String?
    var completed = 0
}

struct AssetTagsView: View {
    let asset: KeepsAsset
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var batch: AIEditingBatchStore
    private var ai: AIEditingSettingsStore { batch.editor }
    @StateObject private var progress = TagGenerationProgress()
    @State private var draft = ""
    @State private var vocabulary: [String] = []
    @State private var libraryError: String?
    @State private var isLoadingLibrary = false

    private var blocked: Bool { library.isMutating || library.isSelectingAll || library.isOperationBlocking }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标签").font(.headline)
            if !asset.tags.isEmpty {
                ForEach(asset.tags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Button { remove(tag) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("从所选照片移除标签“\(tag)”")
                            .disabled(blocked)
                    }
                }
            }
            HStack {
                TextField("新标签，逗号分隔", text: $draft)
                    .onSubmit { addDraft() }
                Button("添加") { addDraft() }
                    .disabled(blocked || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Menu("从标签库添加（\(vocabulary.count)）") {
                ForEach(vocabulary, id: \.self) { tag in
                    Button(tag) { append([tag]) }
                }
            }
            .disabled(blocked || vocabulary.isEmpty)
            if isLoadingLibrary { ProgressView("加载标签库…").controlSize(.small) }
            if let libraryError {
                Text(libraryError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("重新加载标签库") { Task { await loadVocabulary() } }
            }
            Button("自动生成标签", systemImage: "sparkles") { generate() }
                .disabled(blocked || ai.isBusy)
            Text("仅点击后分析所选照片，逐张追加标签并保存到标签库。使用设置中的 AI 账户。")
                .font(.caption).foregroundStyle(.secondary)
            if library.isMutating, let message = progress.message {
                ProgressView(message).controlSize(.small)
            }
        }
        .task(id: library.configuration) {
            vocabulary = []
            draft = ""
            await loadVocabulary()
        }
        .onChange(of: asset.id) { _, _ in draft = "" }
        .onChange(of: library.isMutating) { _, mutating in
            if !mutating {
                progress.message = nil
                Task { await loadVocabulary() }
            }
        }
    }

    private func loadVocabulary() async {
        guard let client = library.client else { return }
        let configuration = library.configuration
        isLoadingLibrary = true
        libraryError = nil
        defer { if library.configuration == configuration { isLoadingLibrary = false } }
        do {
            let tags = try await client.tagLibrary()
            guard library.configuration == configuration, !Task.isCancelled else { return }
            vocabulary = tags
        } catch {
            guard library.configuration == configuration, !Task.isCancelled else { return }
            libraryError = LibraryStore.describe(error)
        }
    }

    private func addDraft() {
        guard !blocked else { return }
        let tags = draft.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !tags.isEmpty else { return }
        append(tags)
        draft = ""
    }

    private func append(_ tags: [String]) {
        let library = library, configuration = library.configuration
        library.mutateSelected { client, id in
            let current = try await client.asset(id: id)
            guard await library.configuration == configuration else { throw CancellationError() }
            return try await client.updateAsset(id: id, patch: KeepsAssetPatch(tags: PhotoTagSuggestions.merging(current.tags, tags)))
        }
    }

    private func remove(_ tag: String) {
        let library = library, configuration = library.configuration
        library.mutateSelected { client, id in
            let current = try await client.asset(id: id)
            guard await library.configuration == configuration else { throw CancellationError() }
            return try await client.updateAsset(id: id, patch: KeepsAssetPatch(tags: current.tags.filter { $0 != tag }))
        }
    }

    private func generate() {
        let library = library, ai = ai, progress = progress
        let configuration = library.configuration
        let total = library.selectedIDs.count
        progress.completed = 0
        progress.message = "准备分析 1/\(total)"
        library.mutateSelected { client, id in
            guard await library.configuration == configuration else { throw CancellationError() }
            let image = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-tags-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: image) }
            try await client.downloadCurrentStandard(assetID: id, to: image)
            let vocabulary = try await client.tagLibrary()
            guard await library.configuration == configuration else { throw CancellationError() }
            await MainActor.run { progress.message = "正在分析 \(progress.completed + 1)/\(total)" }
            let tags = try await ai.generateTags(image: image, vocabulary: vocabulary)
            guard await library.configuration == configuration else { throw CancellationError() }
            let current = try await client.asset(id: id)
            guard await library.configuration == configuration else { throw CancellationError() }
            let updated = try await client.updateAsset(id: id, patch: KeepsAssetPatch(tags: PhotoTagSuggestions.merging(current.tags, tags)))
            await MainActor.run {
                progress.completed += 1
                progress.message = "已完成 \(progress.completed)/\(total)"
            }
            return updated
        }
    }
}
