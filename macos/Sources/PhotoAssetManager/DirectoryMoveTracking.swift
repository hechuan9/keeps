import Foundation
import KeepsAPI

struct PendingDirectoryMove: Codable {
    let id: UUID
    let path: String
    let parentPath: String
    let baseURL: String
    let libraryID: String
    let startedAt: Date
    var accepted: Bool
    var terminalError: String? = nil
    var name: String? = nil
}

@MainActor extension LibraryStore {
    private static let moveKey = "keeps.pendingDirectoryMove"

    func moveDirectory(_ path: String, to parentPath: String) async {
        guard canMoveDirectory(path, to: parentPath) else { return }
        await beginDirectoryMove(path, parentPath: parentPath)
    }

    func canRenameDirectory(_ path: String) -> Bool {
        client != nil && !isOperationBlocking && !isMutating &&
        !isUpdatingHiddenDirectory && !isCheckingConnection && path.hasPrefix("/") &&
        path != "/" && !directories.contains { $0.path == path }
    }

    func canRenameDirectory(_ path: String, name: String) -> Bool {
        canRenameDirectory(path) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !name.hasPrefix(".") && name != "@eaDir" && name != "#recycle" &&
        !name.contains("/") && !name.contains("\\") && name.rangeOfCharacter(from: .controlCharacters) == nil &&
        name != (path as NSString).lastPathComponent
    }

    func renameDirectory(_ path: String, name: String) async {
        guard canRenameDirectory(path, name: name) else { return }
        await beginDirectoryMove(path, parentPath: (path as NSString).deletingLastPathComponent, name: name)
    }

    private func beginDirectoryMove(_ path: String, parentPath: String, name: String? = nil) async {
        guard let configuration else { return }
        directoryMove = PendingDirectoryMove(id: UUID(), path: path, parentPath: parentPath,
            baseURL: configuration.baseURL.absoluteString, libraryID: configuration.libraryID,
            startedAt: Date(), accepted: false, name: name)
        pauseLibraryForDirectoryOperation()
        directoryMoveFinished = false
        directoryMovePhase = "waiting"
        directoryMoveMessage = nil
        lastError = nil
        do { try persistDirectoryMove() }
        catch { finishDirectoryMoveWithError(Self.describe(error)); return }
        await trackDirectoryMove(submit: true)
    }

    private func persistDirectoryMove() throws {
        preferences.set(try JSONEncoder().encode(directoryMove), forKey: Self.moveKey)
    }

    func restoreDirectoryMove() {
        guard let data = preferences.data(forKey: Self.moveKey) else { return }
        do {
            directoryMove = try JSONDecoder().decode(PendingDirectoryMove.self, from: data)
            guard let pending = directoryMove else { return }
            guard configuration?.baseURL.absoluteString == pending.baseURL,
                  configuration?.libraryID == pending.libraryID else {
                finishDirectoryMoveWithError("待确认的移动任务属于其他服务器连接。请在原服务器核实结果。")
                return
            }
            if let error = pending.terminalError { finishDirectoryMoveWithError(error) }
            else { directoryMoveTracking = Task { await trackDirectoryMove(submit: false) } }
        } catch { lastError = "无法恢复移动任务：\n" + Self.describe(error) }
    }

    private func trackDirectoryMove(submit: Bool) async {
        guard let client else { return }
        var shouldSubmit = submit
        while let pending = directoryMove, !Task.isCancelled {
            let submitting = shouldSubmit
            do {
                let task: KeepsDirectoryMoveTask
                if shouldSubmit {
                    shouldSubmit = false
                    task = try await client.startDirectoryMove(path: pending.path, parentPath: pending.parentPath, requestID: pending.id, name: pending.name)
                } else { task = try await client.directoryMoveTask(id: pending.id) }
                guard task.id == pending.id, task.path == pending.path, task.parentPath == pending.parentPath,
                      task.destination == (pending.parentPath as NSString).appendingPathComponent(pending.name ?? (pending.path as NSString).lastPathComponent) else {
                    finishDirectoryMoveWithError("NAS 返回的移动任务与当前请求不一致，请在服务器核实。")
                    return
                }
                directoryMove?.accepted = true
                try persistDirectoryMove()
                directoryMovePhase = task.phase
                directoryMoveMessage = nil
                if task.status == "completed" {
                    completeDirectoryMove(path: pending.path, parentPath: pending.parentPath, destination: task.destination)
                    return
                }
                if task.status == "failed" {
                    finishDirectoryMoveWithError(task.error ?? "NAS 报告移动失败，但未提供原因。")
                    return
                }
            } catch {
                if case KeepsAPIError.http(let status, _) = error, status == 404 && !submitting {
                    if pending.accepted {
                        finishDirectoryMoveWithError("NAS 已接受移动任务，但现在找不到记录。请核实目录位置；不会重复移动。\n" + Self.describe(error))
                        return
                    }
                    shouldSubmit = true
                } else if case KeepsAPIError.http(let status, _) = error,
                          status == 401 || status == 403 || ((400..<500).contains(status) && status != 429 && submitting && !pending.accepted) {
                    finishDirectoryMoveWithError(Self.describe(error))
                    return
                }
                directoryMoveMessage = "正在重新连接 NAS 以确认进度，后台任务会继续执行。\n" + Self.describe(error)
            }
            do { try await Task.sleep(for: directoryMovePollInterval) }
            catch { return }
        }
    }

    private func finishDirectoryMoveWithError(_ message: String) {
        directoryMove?.terminalError = message
        directoryMoveFinished = true
        directoryMovePhase = "failed"
        directoryMoveMessage = message
        lastError = message
        do { try persistDirectoryMove() }
        catch { directoryMoveMessage = message + "\n无法保存任务结果：\n" + Self.describe(error) }
    }

    func acknowledgeDirectoryMoveFailure() {
        guard directoryMoveFinished else { return }
        directoryMove = nil
        preferences.removeObject(forKey: Self.moveKey)
        refreshNavigation()
        refresh(force: true)
    }
}
