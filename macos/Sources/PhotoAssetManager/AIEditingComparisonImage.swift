import ImageIO
import KeepsAPI
import SwiftUI

struct AIEditingComparisonImage: View {
    let url: URL?
    let asset: KeepsAsset?
    let configuration: KeepsConfiguration?
    var onImageSize: (CGSize) -> Void = { _ in }
    @State private var image: CGImage?
    @State private var loadedURL: URL?
    @State private var error: String?

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if let asset {
                KeepsPreviewImage(asset: asset, configuration: configuration, loadStandard: true)
            } else {
                Text(error ?? "等待预览").foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = nil
            loadedURL = nil
            error = nil
            guard let url else { return }
            let decoding = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try AIEditingImages.comparisonPreview(url)
            }
            do {
                let decoded = try await withTaskCancellationHandler {
                    try await decoding.value
                } onCancel: { decoding.cancel() }
                try Task.checkCancellation()
                image = decoded
                loadedURL = url
                onImageSize(CGSize(width: decoded.width, height: decoded.height))
            } catch {
                guard !Task.isCancelled else { return }
                self.error = String(reflecting: error)
            }
        }
    }
}
