import Foundation
import KeepsAPI

struct PendingRejectedTrash: Codable {
    let id: UUID
    let count: Int
    let baseURL: String
    let libraryID: String
    var terminalError: String?
}

@MainActor extension LibraryStore {
    private static let rejectedTrashKey = "keeps.pendingRejectedTrash"

    func previewRejectedTrash() async {
        guard !isOperationBlocking, !isMutating, !isCheckingConnection, !isUpdatingHiddenDirectory, !isImportingPhotos, let client else { return }
        rejectedTrashPreviewConfiguration = configuration
        isPreparingRejectedTrash = true
        rejectedTrashPreview = nil
        rejectedTrashMessage = nil
        rejectedTrashFinished = false
        defer { isPreparingRejectedTrash = false }
        do { rejectedTrashPreview = try await client.previewRejectedTrash() }
        catch { rejectedTrashMessage = Self.describe(error) }
    }

    func canConfirmRejectedTrash(_ text: String) -> Bool {
        guard let preview = rejectedTrashPreview else { return false }
        return rejectedTrashPreviewConfiguration == configuration && preview.status == "draft" && preview.count > 0 && text == String(preview.count)
            && !isOperationBlocking && !isMutating && !isCheckingConnection && !isUpdatingHiddenDirectory && !isImportingPhotos
    }

    func submitRejectedTrash(confirmation: String) async {
        guard canConfirmRejectedTrash(confirmation), let preview = rejectedTrashPreview, let configuration else { return }
        rejectedTrash = PendingRejectedTrash(id: preview.id, count: preview.count,
            baseURL: configuration.baseURL.absoluteString, libraryID: configuration.libraryID)
        pauseLibraryForDirectoryOperation()
        do { try persistRejectedTrash() }
        catch { failRejectedTrash(Self.describe(error)); return }
        await trackRejectedTrash(submit: true)
    }

    private func persistRejectedTrash() throws {
        preferences.set(try JSONEncoder().encode(rejectedTrash), forKey: Self.rejectedTrashKey)
    }

    func restoreRejectedTrash() {
        guard let data = preferences.data(forKey: Self.rejectedTrashKey) else { return }
        do {
            rejectedTrash = try JSONDecoder().decode(PendingRejectedTrash.self, from: data)
            showsRejectedTrash = true
            guard let pending = rejectedTrash,
                  configuration?.baseURL.absoluteString == pending.baseURL,
                  configuration?.libraryID == pending.libraryID else {
                failRejectedTrash("删除任务属于其他服务器连接，请在原服务器核实结果。不会向当前服务器提交删除。")
                return
            }
            if let message = pending.terminalError { failRejectedTrash(message) }
            else { rejectedTrashTracking = Task { await trackRejectedTrash(submit: false) } }
        } catch { lastError = "无法恢复弃用照片删除任务：\n" + Self.describe(error) }
    }

    private func trackRejectedTrash(submit: Bool) async {
        guard let client else { return }
        var shouldSubmit = submit
        while let pending = rejectedTrash, !Task.isCancelled {
            do {
                let task: KeepsRejectedTrashTask
                if shouldSubmit {
                    shouldSubmit = false
                    task = try await client.submitRejectedTrash(id: pending.id, confirmationCount: pending.count)
                } else { task = try await client.rejectedTrashTask(id: pending.id) }
                guard task.id == pending.id, task.count == pending.count else {
                    failRejectedTrash("服务器返回的删除任务与已确认清单不一致，请在 NAS 核实结果。")
                    return
                }
                rejectedTrashPreview = task
                rejectedTrashMessage = nil
                if task.status == "completed" {
                    rejectedTrash = nil
                    preferences.removeObject(forKey: Self.rejectedTrashKey)
                    rejectedTrashFinished = true
                    resetNavigation(); refreshNavigation(); refresh(force: true)
                    return
                }
                if task.status == "failed" { failRejectedTrash(task.error ?? "服务器报告删除失败。"); return }
                if task.status == "draft" { shouldSubmit = true }
            } catch {
                if case KeepsAPIError.http(let status, _) = error, (400..<500).contains(status) {
                    failRejectedTrash(status == 409
                        ? "弃用照片清单已变化，请关闭后重新预览并确认数量。\n" + Self.describe(error)
                        : "无法确认删除任务，请在 NAS 核实；不会创建替代删除请求。\n" + Self.describe(error))
                    return
                }
                rejectedTrashMessage = "暂时无法确认进度，正在查询同一任务。退出应用不会取消后台任务。\n" + Self.describe(error)
            }
            do { try await Task.sleep(for: rejectedTrashPollInterval) } catch { return }
        }
    }

    private func failRejectedTrash(_ message: String) {
        rejectedTrash?.terminalError = message
        rejectedTrashFinished = true
        rejectedTrashMessage = message
        do { try persistRejectedTrash() }
        catch { rejectedTrashMessage = message + "\n无法保存任务结果：\n" + Self.describe(error) }
    }

    func closeRejectedTrash() {
        guard rejectedTrash == nil || rejectedTrashFinished else { return }
        rejectedTrash = nil
        rejectedTrashPreview = nil
        preferences.removeObject(forKey: Self.rejectedTrashKey)
        rejectedTrashFinished = false
        showsRejectedTrash = false
        refreshNavigation(); refresh(force: true)
    }
}
