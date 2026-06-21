import AppKit
import Combine
import ImageIO

@MainActor
final class ImageDocument: ObservableObject {
    enum OpenResult {
        case opened
        case failed
        case superseded
    }

    @Published private(set) var image: NSImage?
    @Published private(set) var fileURL: URL?
    @Published private(set) var isShowingLoadingIndicator = false

    private var isAccessingSecurityScopedResource = false
    private var loadingIndicatorTask: Task<Void, Never>?
    private var loadIdentifier = UUID()

    var displayName: String {
        fileURL?.lastPathComponent ?? "SimpView"
    }

    func open(_ url: URL) async -> OpenResult {
        let identifier = UUID()
        loadIdentifier = identifier
        isShowingLoadingIndicator = false
        scheduleLoadingIndicator(for: identifier)

        let beganAccess = url.startAccessingSecurityScopedResource()
        let decodedImage = await Task.detached(priority: .userInitiated) {
            Self.decodeImage(at: url)
        }.value

        guard loadIdentifier == identifier else {
            if beganAccess {
                url.stopAccessingSecurityScopedResource()
            }
            return .superseded
        }

        loadingIndicatorTask?.cancel()
        isShowingLoadingIndicator = false

        guard let decodedImage else {
            if beganAccess {
                url.stopAccessingSecurityScopedResource()
            }
            return .failed
        }

        stopAccessingCurrentFile()
        image = NSImage(
            cgImage: decodedImage,
            size: NSSize(width: decodedImage.width, height: decodedImage.height)
        )
        fileURL = url
        isAccessingSecurityScopedResource = beganAccess
        return .opened
    }

    func close() {
        loadIdentifier = UUID()
        loadingIndicatorTask?.cancel()
        isShowingLoadingIndicator = false
        stopAccessingCurrentFile()
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

    private func stopAccessingCurrentFile() {
        if isAccessingSecurityScopedResource, let fileURL {
            fileURL.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedResource = false
    }

    nonisolated private static func decodeImage(at url: URL) -> CGImage? {
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
