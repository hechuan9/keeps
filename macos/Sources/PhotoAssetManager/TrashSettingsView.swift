import SwiftUI
import KeepsAPI

struct TrashSettingsView: View {
    let client: KeepsClient
    @State private var settings = KeepsTrashSettings()
    @State private var loaded = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Toggle("自动清理 Keeps 回收站", isOn: $settings.enabled)
            HStack {
                Text("保留天数")
                TextField("30", value: $settings.retentionDays, format: .number)
                    .frame(width: 80)
                Text("天（1–3650）").foregroundStyle(.secondary)
            }
            .disabled(!settings.enabled)
            Text("删除照片先进入 Keeps 回收站。到期后，NAS 后台将原片及关联文件移入 DSM 回收站，并清理图库资料和缓存。关闭自动清理后可手动清空。")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).textSelection(.enabled) }
            Button("保存") {
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        settings = try await client.updateTrashSettings(settings)
                        message = "已保存"
                    } catch { message = LibraryStore.describe(error) }
                }
            }
            .disabled(!loaded || busy || !(1...3650).contains(settings.retentionDays))
        }
        .padding(24).frame(width: 520)
        .disabled(!loaded || busy)
        .overlay { if busy { ProgressView() } }
        .task {
            busy = true
            defer { busy = false }
            do {
                settings = try await client.trashSettings()
                loaded = true
            } catch { message = LibraryStore.describe(error) }
        }
    }
}
