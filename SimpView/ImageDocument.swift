import AppKit
import Combine

@MainActor
final class ImageDocument: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var fileURL: URL?

    private var isAccessingSecurityScopedResource = false

    var displayName: String {
        fileURL?.lastPathComponent ?? "SimpView"
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        let beganAccess = url.startAccessingSecurityScopedResource()

        guard let newImage = NSImage(contentsOf: url) else {
            if beganAccess {
                url.stopAccessingSecurityScopedResource()
            }
            return false
        }

        stopAccessingCurrentFile()
        image = newImage
        fileURL = url
        isAccessingSecurityScopedResource = beganAccess
        return true
    }

    func close() {
        stopAccessingCurrentFile()
    }

    private func stopAccessingCurrentFile() {
        if isAccessingSecurityScopedResource, let fileURL {
            fileURL.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedResource = false
    }

}
