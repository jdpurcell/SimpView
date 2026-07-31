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
    @Published private(set) var isResolvingURL = false
    @Published private(set) var isShowingLoadingIndicator = false
    @Published private(set) var hasDecodeError = false

    private var loadingIndicatorTask: Task<Void, Never>?
    private var loadIdentifier = UUID()

    var displayName: String {
        fileURL?.lastPathComponent ?? "SimpView"
    }

    func open(
        resolvingURL: () async -> URL?,
        didResolveURL: (URL) -> Void = { _ in },
        decode: (URL) async -> CGImage?,
        showsLoadingIndicatorImmediately: Bool = false
    ) async -> OpenResult {
        let identifier = UUID()
        loadIdentifier = identifier
        isLoading = true
        isResolvingURL = true
        if showsLoadingIndicatorImmediately {
            loadingIndicatorTask?.cancel()
            loadingIndicatorTask = nil
            isShowingLoadingIndicator = true
        } else {
            isShowingLoadingIndicator = false
            scheduleLoadingIndicator(for: identifier)
        }

        let resolvedURL = await resolvingURL()

        guard loadIdentifier == identifier, !Task.isCancelled else {
            return .superseded
        }

        isResolvingURL = false
        guard let url = resolvedURL else {
            finishLoading(identifier: identifier)
            return .unchanged
        }

        fileURL = url
        hasDecodeError = false
        didResolveURL(url)

        let decodedImage = await decode(url)

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
        isResolvingURL = false
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
        isResolvingURL = false
        isShowingLoadingIndicator = false
    }

    nonisolated static func decodeImage(
        at url: URL,
        mode: ImageDecodeMode
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maximumDimension = max(width, height)
        var commonOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if mode == .hdr {
            commonOptions[kCGImageSourceDecodeRequest] =
                kCGImageSourceDecodeToHDR
        }

        if maximumDimension > 0 {
            var thumbnailOptions = commonOptions
            thumbnailOptions[kCGImageSourceCreateThumbnailFromImageAlways] = true
            thumbnailOptions[kCGImageSourceCreateThumbnailWithTransform] = true
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] =
                maximumDimension

            if let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) {
                return image
            }
        }

        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            commonOptions as CFDictionary
        )
    }
}
