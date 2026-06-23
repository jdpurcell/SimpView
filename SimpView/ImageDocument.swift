import AppKit
import Combine
import ImageIO

@MainActor
final class ImageDocument: ObservableObject {
    enum OpenResult {
        case opened(URL)
        case failed(URL)
        case unchanged
        case superseded
    }

    @Published private(set) var image: NSImage?
    @Published private(set) var fileURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingLoadingIndicator = false
    @Published private(set) var hasDecodeError = false

    private var loadingIndicatorTask: Task<Void, Never>?
    private var loadIdentifier = UUID()

    var displayName: String {
        fileURL?.lastPathComponent ?? "SimpView"
    }

    func open(_ url: URL) async -> OpenResult {
        await open(resolvingURL: { url })
    }

    func open(
        resolvingURL: () async -> URL?,
        didResolveURL: (URL) -> Void = { _ in },
        decode: ((URL) async -> CGImage?)? = nil
    ) async -> OpenResult {
        let identifier = UUID()
        loadIdentifier = identifier
        isLoading = true
        isShowingLoadingIndicator = false
        scheduleLoadingIndicator(for: identifier)

        guard let url = await resolvingURL() else {
            finishLoading(identifier: identifier)
            return loadIdentifier == identifier ? .unchanged : .superseded
        }

        guard loadIdentifier == identifier, !Task.isCancelled else {
            return .superseded
        }

        fileURL = url
        hasDecodeError = false
        didResolveURL(url)

        let decodedImage: CGImage?
        if let decode {
            decodedImage = await decode(url)
        } else {
            decodedImage = await Task.detached(priority: .userInitiated) {
                Self.decodeImage(at: url)
            }.value
        }

        guard loadIdentifier == identifier else {
            return .superseded
        }

        guard let decodedImage else {
            hasDecodeError = true
            image = nil
            finishLoading(identifier: identifier)
            return .failed(url)
        }

        image = NSImage(
            cgImage: decodedImage,
            size: NSSize(width: decodedImage.width, height: decodedImage.height)
        )
        hasDecodeError = false
        finishLoading(identifier: identifier)
        return .opened(url)
    }

    func close() {
        loadIdentifier = UUID()
        loadingIndicatorTask?.cancel()
        isLoading = false
        isShowingLoadingIndicator = false
        image = nil
        fileURL = nil
        hasDecodeError = false
    }

    private func scheduleLoadingIndicator(for identifier: UUID) {
        loadingIndicatorTask?.cancel()
        loadingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard
                !Task.isCancelled,
                let self,
                self.loadIdentifier == identifier
            else {
                return
            }
            self.isShowingLoadingIndicator = true
        }
    }

    private func finishLoading(identifier: UUID) {
        guard loadIdentifier == identifier else {
            return
        }

        loadingIndicatorTask?.cancel()
        loadingIndicatorTask = nil
        isLoading = false
        isShowingLoadingIndicator = false
    }

    nonisolated static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maximumDimension = max(width, height)

        if maximumDimension > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]

            if let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) {
                return image
            }
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
