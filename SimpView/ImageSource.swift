import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageReference: Hashable, Sendable {
    case file(URL)
    case camera(session: UUID, item: UUID, name: String, path: String)

    // Camera names/paths are presentation metadata, not object identity.
    static func == (left: Self, right: Self) -> Bool {
        switch (left, right) {
        case (.file(let a), .file(let b)): a == b
        case (.camera(let a, let x, _, _), .camera(let b, let y, _, _)): a == b && x == y
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .file(let url):
            hasher.combine(0)
            hasher.combine(url)
        case .camera(let session, let item, _, _):
            hasher.combine(1)
            hasher.combine(session)
            hasher.combine(item)
        }
    }

    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    var name: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .camera(_, _, let name, _): name
        }
    }

    var path: String {
        switch self {
        case .file(let url): url.path
        case .camera(_, _, _, let path): path
        }
    }

    var collectionID: String {
        switch self {
        case .file(let url): url.standardizedFileURL.deletingLastPathComponent().absoluteString
        case .camera(let session, _, _, _): session.uuidString
        }
    }
}

struct ImageEntry: Sendable, Equatable, Identifiable {
    var id: ImageReference { image }
    let image: ImageReference
    let modificationDate: Date
    let fileSize: Int

    static func == (left: Self, right: Self) -> Bool {
        left.image == right.image && left.image.name == right.image.name
            && left.image.path == right.image.path
            && left.modificationDate == right.modificationDate && left.fileSize == right.fileSize
    }

    static func sorted(_ entries: [Self], field: ImageSortField, direction: SortDirection) -> [Self] {
        entries.sorted { left, right in
            let comparison: ComparisonResult = switch field {
            case .name: left.image.name.localizedStandardCompare(right.image.name)
            case .modificationDate: left.modificationDate.compare(right.modificationDate)
            }
            let order = comparison == .orderedSame
                ? left.image.path.compare(right.image.path) : comparison
            return order == (direction == .ascending ? .orderedAscending : .orderedDescending)
        }
    }
}

enum SupportedImages {
    private static let types = Set(CGImageSourceCopyTypeIdentifiers() as! [String])

    static func contains(filename: String) -> Bool {
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else { return false }
        return types.contains(type.identifier)
    }
}

struct ImageFileDates: Sendable {
    let creation: Date?
    let modification: Date?

    func apply(to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        if let creation { attributes[.creationDate] = creation }
        if let modification { attributes[.modificationDate] = modification }
        if !attributes.isEmpty {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}

// Each window owns a source. Camera sources share the device session and read
// queue, while navigation and presentation only deal with image references.
@MainActor
protocol ImageSource: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    var isAvailable: Bool { get }
    var refreshesOnActivation: Bool { get }
    func entries(for image: ImageReference) async -> [ImageEntry]
    func load(_ image: ImageReference, mode: ImageDecodeMode) async throws -> CGImage?
    func saveCopy(_ image: ImageReference, to destination: URL) async throws
    func preload(current: ImageReference, neighbors: [ImageEntry], mode: ImageDecodeMode) async
    func setPreloadingEnabled(_ enabled: Bool) async
    func setDecodeMode(_ mode: ImageDecodeMode) async
    func close()
}

extension ImageSource {
    func preload(current: ImageReference, neighbors: [ImageEntry], mode: ImageDecodeMode) async {}
    func setPreloadingEnabled(_ enabled: Bool) async {}
    func setDecodeMode(_ mode: ImageDecodeMode) async {}
}

@MainActor
final class FileImageSource: ImageSource {
    let changes = Empty<Void, Never>().eraseToAnyPublisher()
    let isAvailable = true
    let refreshesOnActivation = true
    private let cache = ImagePreloadCache()

    func saveCopy(_ image: ImageReference, to destination: URL) async throws {
        guard let source = image.fileURL else { throw CocoaError(.fileNoSuchFile) }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // Read fresh attributes rather than any metadata cached on the URL
            // while browsing or preloading.
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let dates = ImageFileDates(creation: attributes[.creationDate] as? Date,
                                       modification: attributes[.modificationDate] as? Date)
            let data = try Data(contentsOf: source)
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
            try dates.apply(to: destination)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func entries(for image: ImageReference) async -> [ImageEntry] {
        guard let url = image.fileURL else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return urls.compactMap { url in
                guard !Task.isCancelled,
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      SupportedImages.contains(filename: url.lastPathComponent)
                else { return nil }
                return ImageEntry(image: .file(url), modificationDate: values.contentModificationDate ?? .distantPast, fileSize: values.fileSize ?? -1)
            }
        }.value
    }

    func load(_ image: ImageReference, mode: ImageDecodeMode) async throws -> CGImage? {
        guard let url = image.fileURL else { return nil }
        if AppPreferences.shared.preloadAdjacentImages {
            return await cache.image(at: url, mode: mode)
        }
        return await Task.detached(priority: .userInitiated) {
            ImageDocument.decodeImage(at: url, mode: mode)
        }.value
    }

    func preload(current: ImageReference, neighbors: [ImageEntry], mode: ImageDecodeMode) async {
        guard let url = current.fileURL else { return }
        await cache.updateNeighborhood(currentURL: url, adjacentImages: neighbors, mode: mode)
    }
    func setPreloadingEnabled(_ enabled: Bool) async { await cache.setEnabled(enabled) }
    func setDecodeMode(_ mode: ImageDecodeMode) async { await cache.setDecodeMode(mode) }
    func close() {
        let cache = cache
        Task { await cache.removeAll() }
    }
}
