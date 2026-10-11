import Foundation
import AppKit
import SwiftUI
import KeepsAPI

struct PhotoDragPayload: Codable {
    static let pasteboardType = "local.keeps.photos"
    let assetIDs: [UUID]
    let sourcePath: String?
    let baseURL: String
    let libraryID: String
    let query: KeepsAssetQuery
}

struct PendingPhotoMove: Codable {
    let id: UUID
    let payload: PhotoDragPayload
    let parentPath: String
    let startedAt: Date
    var accepted: Bool
    var terminalError: String? = nil
}

@MainActor extension LibraryStore {
    private static let photoMoveKey = "keeps.pendingPhotoMove"

    func photoDragPayload(for id: UUID) -> PhotoDragPayload? {
        guard let configuration,
              !query.trashed, !isOperationBlocking, !isMutating,
              !isSelectingAll, hasCurrentPhotoResults, assets.contains(where: { $0.id == id }) else { return nil }
        let ids = selectedIDs.contains(id) ? selectedIDs : [id]
        return PhotoDragPayload(assetIDs: ids.sorted { $0.uuidString < $1.uuidString },
            sourcePath: query.directory, baseURL: configuration.baseURL.absoluteString,
            libraryID: configuration.libraryID, query: query)
    }

    func photoDragItem(for id: UUID) -> NSPasteboardItem? {
        guard let payload = photoDragPayload(for: id) else { return nil }
        do {
            let data = try JSONEncoder().encode(payload)
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(PhotoDragPayload.pasteboardType))
            if !selectedIDs.contains(id) { select(id) }
            return item
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    func canMovePhotos(_ payload: PhotoDragPayload, to parentPath: String) -> Bool {
        client != nil && hasCurrentPhotoResults && !isOperationBlocking && !isMutating && !isSelectingAll &&
        !isUpdatingHiddenDirectory && !isCheckingConnection && !query.trashed &&
        configuration?.baseURL.absoluteString == payload.baseURL && configuration?.libraryID == payload.libraryID &&
        query == payload.query && query.directory == payload.sourcePath &&
        (payload.sourcePath?.hasPrefix("/") ?? true) && parentPath.hasPrefix("/") && payload.sourcePath != parentPath &&
        !payload.assetIDs.isEmpty && Set(payload.assetIDs).count == payload.assetIDs.count &&
        Set(payload.assetIDs).isSubset(of: Set(assets.map(\.id)))
    }

    func movePhotos(_ payload: PhotoDragPayload, to parentPath: String) async {
        guard canMovePhotos(payload, to: parentPath) else { return }
        photoMove = PendingPhotoMove(id: UUID(), payload: payload, parentPath: parentPath, startedAt: Date(), accepted: false)
        pauseLibraryForDirectoryOperation()
        photoMoveFinished = false
        photoMovePhase = "waiting"
        photoMoveMessage = nil
        lastError = nil
        do { try persistPhotoMove() }
        catch { finishPhotoMoveWithError(Self.describe(error)); return }
        await trackPhotoMove(submit: true)
    }

    private func persistPhotoMove() throws {
        preferences.set(try JSONEncoder().encode(photoMove), forKey: Self.photoMoveKey)
    }

    func restorePhotoMove() {
        guard let data = preferences.data(forKey: Self.photoMoveKey) else { return }
        do {
            photoMove = try JSONDecoder().decode(PendingPhotoMove.self, from: data)
            guard let pending = photoMove else { return }
            guard configuration?.baseURL.absoluteString == pending.payload.baseURL,
                  configuration?.libraryID == pending.payload.libraryID else {
                finishPhotoMoveWithError("待确认的移动任务属于其他服务器连接。请在原服务器核实结果。")
                return
            }
            if let error = pending.terminalError { finishPhotoMoveWithError(error) }
            else { photoMoveTracking = Task { await trackPhotoMove(submit: false) } }
        } catch { lastError = "无法恢复移动任务：\n" + Self.describe(error) }
    }

    private func trackPhotoMove(submit: Bool) async {
        guard let client else { return }
        var shouldSubmit = submit
        while let pending = photoMove, !Task.isCancelled {
            let submitting = shouldSubmit
            do {
                let task: KeepsPhotoMoveTask
                if shouldSubmit {
                    shouldSubmit = false
                    task = try await client.startPhotoMove(assetIDs: pending.payload.assetIDs, sourcePath: pending.payload.sourcePath, parentPath: pending.parentPath, requestID: pending.id)
                } else { task = try await client.photoMoveTask(id: pending.id) }
                guard task.id == pending.id, task.sourcePath == pending.payload.sourcePath,
                      task.parentPath == pending.parentPath, Set(task.assetIDs) == Set(pending.payload.assetIDs) else {
                    finishPhotoMoveWithError("NAS 返回的移动任务与当前请求不一致，请在服务器核实。")
                    return
                }
                photoMove?.accepted = true
                try persistPhotoMove()
                photoMovePhase = task.phase
                photoMoveMessage = nil
                if task.status == "completed" {
                    completePhotoMove()
                    return
                }
                if task.status == "failed" {
                    finishPhotoMoveWithError(task.error ?? "NAS 报告移动失败，但未提供原因。")
                    return
                }
            } catch {
                if case KeepsAPIError.http(let status, _) = error, status == 404 && !submitting {
                    if pending.accepted {
                        finishPhotoMoveWithError("NAS 已接受移动任务，但现在找不到记录。请核实照片位置；不会重复移动。\n" + Self.describe(error))
                        return
                    }
                    shouldSubmit = true
                } else if case KeepsAPIError.http(let status, _) = error,
                          status == 401 || status == 403 || ((400..<500).contains(status) && status != 429 && submitting && !pending.accepted) {
                    finishPhotoMoveWithError(Self.describe(error))
                    return
                }
                photoMoveMessage = "正在重新连接 NAS 以确认进度，后台任务会继续执行。\n" + Self.describe(error)
            }
            do { try await Task.sleep(for: photoMovePollInterval) }
            catch { return }
        }
    }

    private func finishPhotoMoveWithError(_ message: String) {
        photoMove?.terminalError = message
        photoMoveFinished = true
        photoMovePhase = "failed"
        photoMoveMessage = message
        lastError = message
        do { try persistPhotoMove() }
        catch { photoMoveMessage = message + "\n无法保存任务结果：\n" + Self.describe(error) }
    }

    func acknowledgePhotoMoveFailure() {
        guard photoMoveFinished else { return }
        photoMove = nil
        preferences.removeObject(forKey: Self.photoMoveKey)
        refreshNavigation()
        refresh(force: true)
    }
}

struct PhotoDragSource: NSViewRepresentable {
    let item: () -> NSPasteboardItem?
    let open: () -> Void
    let select: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }
    func updateNSView(_ view: SourceView, context: Context) {
        view.item = item
        view.open = open
        view.select = select
    }

    final class SourceView: NSView, NSDraggingSource {
        var item: (() -> NSPasteboardItem?)?
        var open: (() -> Void)?
        var select: ((NSEvent.ModifierFlags) -> Void)?
        private var mouseDownEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 右键交给 SwiftUI 的照片上下文菜单。
            if let type = NSApp.currentEvent?.type,
               [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(type) { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

        override func mouseUp(with event: NSEvent) {
            guard mouseDownEvent != nil else { return }
            mouseDownEvent = nil
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if event.clickCount == 2 {
                open?()
            } else {
                select?(event.modifierFlags)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent,
                  hypot(event.locationInWindow.x - start.locationInWindow.x,
                        event.locationInWindow.y - start.locationInWindow.y) >= 4 else { return }
            // 原生会话接管事件；取消、拒绝和成功都不保留本次鼠标按下状态。
            mouseDownEvent = nil
            guard let item = item?() else { return }
            let image = NSImage(size: bounds.size)
            if let parent = superview {
                let rect = convert(bounds, to: parent)
                if let bitmap = parent.bitmapImageRepForCachingDisplay(in: rect) {
                    parent.cacheDisplay(in: rect, to: bitmap)
                    image.addRepresentation(bitmap)
                }
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            mouseDownEvent = nil
        }
    }
}
