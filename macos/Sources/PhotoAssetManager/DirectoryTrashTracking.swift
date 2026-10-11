import Foundation
import KeepsAPI

struct PendingDirectoryTrash: Codable {
    let id: UUID
    let path: String
    let name: String
    let baseURL: String
    let libraryID: String
    let startedAt: Date
    var accepted: Bool
    var terminalError: String? = nil
}

@MainActor extension LibraryStore {
    private static let trashKey = "keeps.pendingDirectoryTrash"

    func trashDirectory(_ directory: KeepsNavigationDirectory, confirmationName: String) async throws {
        guard !isOperationBlocking, !isMutating, !isUpdatingHiddenDirectory, !isCheckingConnection,
              let configuration else { throw KeepsAPIError.invalidConfiguration }
        guard confirmationName == directory.name else { throw KeepsAPIError.http(422, "目录名不一致") }
        directoryTrash = PendingDirectoryTrash(id: UUID(), path: directory.path, name: directory.name,
            baseURL: configuration.baseURL.absoluteString, libraryID: configuration.libraryID,
            startedAt: Date(), accepted: false)
        pauseLibraryForDirectoryOperation()
        directoryTrashFinished = false
        directoryTrashPhase = "waiting"
        directoryTrashMessage = nil
        try persistDirectoryTrash()
        await trackDirectoryTrash(submit: true)
    }

    private func persistDirectoryTrash() throws {
        preferences.set(try JSONEncoder().encode(directoryTrash), forKey: Self.trashKey)
    }

    func restoreDirectoryTrash() {
        guard let data = preferences.data(forKey: Self.trashKey) else { return }
        do {
            directoryTrash = try JSONDecoder().decode(PendingDirectoryTrash.self, from: data)
            guard let pending = directoryTrash else { return }
            directoryToTrash = KeepsNavigationDirectory(path: pending.path, name: pending.name, photoCount: 0, hasChildren: false)
            guard configuration?.baseURL.absoluteString == pending.baseURL,
                  configuration?.libraryID == pending.libraryID else {
                finishDirectoryTrashWithError("待确认的删除任务属于其他服务器连接。请先在原服务器核实任务结果；此处不会重新提交删除。")
                return
            }
            if let error = pending.terminalError {
                finishDirectoryTrashWithError(error)
            } else {
                directoryTrashTracking = Task { await trackDirectoryTrash(submit: false) }
            }
        } catch {
            lastError = "无法恢复删除任务：\n" + Self.describe(error)
        }
    }

    private func trackDirectoryTrash(submit: Bool) async {
        guard let client else { return }
        var shouldSubmit = submit
        while let pending = directoryTrash, !Task.isCancelled {
            let submitting = shouldSubmit
            do {
                let task: KeepsDirectoryTrashTask
                if shouldSubmit {
                    shouldSubmit = false
                    task = try await client.trashDirectory(path: pending.path, confirmationName: pending.name, requestID: pending.id)
                } else {
                    task = try await client.directoryTrashTask(id: pending.id)
                }
                guard task.id == pending.id, task.path == pending.path else {
                    finishDirectoryTrashWithError("服务器返回的任务 ID 或目录与当前删除请求不一致。无法确认结果，请在 NAS 核实；不会再次提交删除。")
                    return
                }
                directoryTrash?.accepted = true
                try persistDirectoryTrash()
                directoryTrashPhase = task.phase
                directoryTrashMessage = nil
                if task.status == "completed" {
                    completeDirectoryTrash(path: pending.path)
                    return
                }
                if task.status == "failed" {
                    finishDirectoryTrashWithError(task.error ?? "服务器报告删除失败，但未提供详细原因。")
                    return
                }
            } catch {
                if case KeepsAPIError.http(let status, _) = error, status == 404 && !submitting {
                    if pending.accepted {
                        finishDirectoryTrashWithError("服务器已接受删除任务，但现在无法找到任务记录。请在 NAS 核实目录及回收站状态；不会重新提交删除。\n" + Self.describe(error))
                        return
                    }
                    shouldSubmit = true
                } else if case KeepsAPIError.http(let status, _) = error,
                          (400..<500).contains(status), submitting && !pending.accepted {
                    finishDirectoryTrashWithError(Self.describe(error))
                    return
                }
                directoryTrashMessage = "暂时无法确认进度，正在重新查询。删除可能仍在后台进行，请勿重复提交。\n" + Self.describe(error)
            }
            do { try await Task.sleep(for: directoryTrashPollInterval) }
            catch { return }
        }
    }

    private func finishDirectoryTrashWithError(_ message: String) {
        directoryTrash?.terminalError = message
        directoryTrashFinished = true
        directoryTrashPhase = "failed"
        directoryTrashMessage = message
        do { try persistDirectoryTrash() }
        catch { directoryTrashMessage = message + "\n无法保存任务结果：\n" + Self.describe(error) }
    }

    private func completeDirectoryTrash(path: String) {
        directoryTrash = nil
        preferences.removeObject(forKey: Self.trashKey)
        if let selected = query.directory, selected == path || selected.hasPrefix(path + "/") {
            query = KeepsAssetQuery()
        }
        resetNavigation()
        refreshNavigation()
        refresh(force: true)
    }

    func acknowledgeDirectoryTrashFailure() {
        guard directoryTrashFinished else { return }
        directoryTrash = nil
        directoryToTrash = nil
        preferences.removeObject(forKey: Self.trashKey)
        refreshNavigation()
        refresh(force: true)
    }
}
