import AppKit
import Combine
import ImageIO

@MainActor
final class ImageDocument: ObservableObject {
    enum OpenResult {
        case opened(ImageReference)
        case failed(ImageReference)
        case unchanged
        case superseded
    }

    @Published private(set) var image: NSImage?
    @Published private(set) var reference: ImageReference?
    var fileURL: URL? { reference?.fileURL }
    @Published private(set) var errorMessage = "The image format isn’t supported, or the file is damaged."
    @Published private(set) var isLoading = false
    @Published private(set) var isResolvingImage = false
    @Published private(set) var isShowingLoadingIndicator = false
    @Published private(set) var hasDecodeError = false

    private var loadingIndicatorTask: Task<Void, Never>?
    private var loadIdentifier = UUID()

    var displayName: String {
        reference?.name ?? "SimpView"
    }

    func open(
        resolvingImage: () async -> ImageReference?,
        didResolveImage: (ImageReference) -> Void = { _ in },
        decode: (ImageReference) async throws -> CGImage?,
        showsLoadingIndicatorImmediately: Bool = false
    ) async -> OpenResult {
        let identifier = UUID()
        loadIdentifier = identifier
        isLoading = true
        isResolvingImage = true
        if showsLoadingIndicatorImmediately {
            loadingIndicatorTask?.cancel()
            loadingIndicatorTask = nil
            isShowingLoadingIndicator = true
        } else {
            isShowingLoadingIndicator = false
            scheduleLoadingIndicator(for: identifier)
        }

        let resolvedImage = await resolvingImage()

        guard loadIdentifier == identifier, !Task.isCancelled else {
            return .superseded
        }

        isResolvingImage = false
        guard let reference = resolvedImage else {
            finishLoading(identifier: identifier)
            return .unchanged
        }

        self.reference = reference
        hasDecodeError = false
        didResolveImage(reference)

        var failureMessage = "The image format isn’t supported, or the file is damaged."
        let decodedImage: CGImage?
        do {
            decodedImage = try await decode(reference)
        } catch is CancellationError {
            return .superseded
        } catch {
            failureMessage = error.localizedDescription
            decodedImage = nil
        }

        guard loadIdentifier == identifier, !Task.isCancelled else {
            return .superseded
        }

        guard let decodedImage else {
            errorMessage = failureMessage
            hasDecodeError = true
            image = nil
            finishLoading(identifier: identifier)
            return .failed(reference)
        }

        image = NSImage(
            cgImage: decodedImage,
            size: NSSize(width: decodedImage.width, height: decodedImage.height)
        )
        hasDecodeError = false
        finishLoading(identifier: identifier)
        return .opened(reference)
    }

    func close() {
        loadIdentifier = UUID()
        loadingIndicatorTask?.cancel()
        isLoading = false
        isResolvingImage = false
        isShowingLoadingIndicator = false
        image = nil
        reference = nil
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
        isResolvingImage = false
        isShowingLoadingIndicator = false
    }

    nonisolated static func decodeImage(
        at url: URL,
        mode: ImageDecodeMode
    ) -> CGImage? {
        decodeImage(source: CGImageSourceCreateWithURL(url as CFURL, nil), mode: mode)
    }

    nonisolated static func decodeImage(data: Data, mode: ImageDecodeMode) -> CGImage? {
        decodeImage(source: CGImageSourceCreateWithData(data as CFData, nil), mode: mode)
    }

    nonisolated private static func decodeImage(source: CGImageSource?, mode: ImageDecodeMode) -> CGImage? {
        guard let source else {
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
