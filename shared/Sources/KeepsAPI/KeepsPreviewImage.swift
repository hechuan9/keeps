import SwiftUI

public struct KeepsPreviewImage: View {
    public let asset: KeepsAsset
    public let configuration: KeepsConfiguration?
    private let contentMode: ContentMode
    private let loadStandard: Bool
    private let previewScale: CGFloat
    private let placeholderDelay: Duration
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var imageQuality = 0
    @State private var imageIdentity: String?
    @State private var imageConfiguration: KeepsConfiguration?
    @State private var error: String?
    @State private var retry = 0
    @State private var revealedPlaceholderKey: String?

    public init(asset: KeepsAsset, configuration: KeepsConfiguration?, contentMode: ContentMode = .fit, loadStandard: Bool = false, previewScale: CGFloat = 1, placeholderDelay: Duration = .zero) {
        self.asset = asset
        self.configuration = configuration
        self.contentMode = contentMode
        self.loadStandard = loadStandard
        self.previewScale = previewScale
        self.placeholderDelay = placeholderDelay
    }

    private var identity: String {
        "\(asset.id)|\(asset.gridPreview?.version ?? "")|\(asset.standard?.version ?? "")"
    }

    private var placeholderKey: String {
        "\(identity)|\(configuration?.baseURL.absoluteString ?? "")|\(configuration?.libraryID ?? "")|\(configuration?.accessCredential ?? "")|\(retry)"
    }

    public var body: some View {
        GeometryReader { geometry in
            let maxPixelSize = max(1, Int(ceil(max(geometry.size.width, geometry.size.height) * displayScale)))
            let standardSize = asset.standard.map { max($0.width, $0.height) } ?? maxPixelSize
            let standardPixels = previewScale >= 5 ? standardSize : min(standardSize, Int(ceil(CGFloat(maxPixelSize) * max(1, previewScale))))
            ZStack {
                Color(white: 0.15)
                if placeholderDelay == .zero || revealedPlaceholderKey == placeholderKey {
                    Image(decorative: KeepsThumbnailPlaceholder.image, scale: 1)
                        .resizable().frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let image, imageIdentity == identity, imageConfiguration == configuration {
                    Image(decorative: image, scale: displayScale)
                        .resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                if asset.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: min(44, max(24, geometry.size.height * 0.3))))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 4)
                        .accessibilityHidden(true)
                }
            }
            .transaction { $0.animation = nil }
            .overlay(alignment: .bottom) {
                if loadStandard, let error {
                    VStack {
                        Button("重新载入照片") { retry += 1 }
                        Text(error).font(.caption2).lineLimit(3)
                    }.padding(8).background(.regularMaterial)
                }
            }
            .accessibilityLabel(error ?? (asset.gridPreview == nil ? "缩略图尚未生成" : asset.originalFilename))
            .accessibilityAction(named: "重新载入缩略图") { retry += 1 }
            .task(id: placeholderKey) {
                let key = placeholderKey
                revealedPlaceholderKey = nil
                do {
                    try await Task.sleep(for: placeholderDelay)
                    try Task.checkCancellation()
                    revealedPlaceholderKey = key
                } catch is CancellationError {
                    return
                } catch {
                    assertionFailure(String(reflecting: error))
                }
            }
            .task(id: "\(identity)|\(asset.browseThumbnail?.version ?? "")|\(configuration?.baseURL.absoluteString ?? "")|\(configuration?.libraryID ?? "")|\(configuration?.accessCredential ?? "")|\(loadStandard)|\(maxPixelSize)|\(standardPixels)|\(retry)") {
                await load(maxPixelSize: maxPixelSize, standardPixels: standardPixels)
            }
        }
    }

    @MainActor
    private func load(maxPixelSize: Int, standardPixels: Int) async {
        if imageIdentity != identity || imageConfiguration != configuration {
            image = nil
            imageQuality = 0
        }
        imageIdentity = identity
        imageConfiguration = configuration
        error = nil
        guard let configuration else { return }
        if loadStandard, let standard = asset.standard {
            async let highResolution: Void = display(standard, role: .standard, configuration: configuration,
                                                     pixels: standardPixels, quality: 3)
            await loadThumbnails(configuration: configuration, maxPixelSize: maxPixelSize)
            await highResolution
        } else {
            await loadThumbnails(configuration: configuration, maxPixelSize: maxPixelSize)
        }
    }

    @MainActor
    private func loadThumbnails(configuration: KeepsConfiguration, maxPixelSize: Int) async {
        if image == nil, let browse = asset.browseThumbnail {
            await display(browse, role: .browse, configuration: configuration, pixels: 64, quality: 1)
        }
        guard !Task.isCancelled, imageQuality < 3 else { return }
        if let preview = asset.gridPreview {
            await display(preview, role: asset.thumbnail == nil ? .preview : .thumbnail,
                          configuration: configuration, pixels: maxPixelSize, quality: 2)
        }
    }

    @MainActor
    private func display(_ descriptor: KeepsPreview, role: KeepsMediaRole, configuration: KeepsConfiguration, pixels: Int, quality: Int) async {
        do {
            let loaded = try await PreviewCache.cache(for: role).image(
                assetID: asset.id, preview: descriptor, configuration: configuration, maxPixelSize: pixels
            )
            try Task.checkCancellation()
            guard quality >= imageQuality else { return }
            if quality == imageQuality, let image,
               max(loaded.width, loaded.height) < max(image.width, image.height) { return }
            image = loaded
            imageQuality = quality
            if !loadStandard || quality == 3 { error = nil }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if quality == 3 || (!loadStandard && quality >= imageQuality) {
                self.error = String(reflecting: error)
            }
        }
    }
}
