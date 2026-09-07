import CoreGraphics
import Foundation

// Each window keeps only its current image and neighbors. The camera's shared
// read queue handles scheduling; this cache owns decoded images and in-flight work.
@MainActor
final class CameraImageCache {
    typealias Loader = @MainActor (ImageReference, ImageDecodeMode, UUID, Bool) async throws -> CGImage?

    private final class Load {
        let id = UUID()
        let entry: ImageEntry
        var isBackground: Bool
        var isFinished = false
        var task: Task<CGImage?, Error>!

        init(entry: ImageEntry, isBackground: Bool) {
            self.entry = entry
            self.isBackground = isBackground
        }
    }

    private var loads: [ImageReference: Load] = [:]
    private var current: ImageReference?
    private var mode: ImageDecodeMode?
    private var enabled = true
    private let loader: Loader
    private let promote: (UUID) -> Void

    init(loader: @escaping Loader, promote: @escaping (UUID) -> Void) {
        self.loader = loader
        self.promote = promote
    }

    func image(_ entry: ImageEntry, mode: ImageDecodeMode) async throws -> CGImage? {
        try Task.checkCancellation()
        setDecodeMode(mode)
        current = entry.image
        let load = load(entry, mode: mode, background: false)
        let task = load.task!
        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            if !enabled || image == nil { remove(entry.image, matching: load) }
            return image
        } catch {
            remove(entry.image, matching: load)
            throw error
        }
    }

    func updateNeighborhood(current: ImageReference, neighbors: [ImageEntry], mode: ImageDecodeMode) {
        guard enabled, self.current == current else { return }
        setDecodeMode(mode)
        let retained = Set(neighbors.map(\.image)).union([current])
        for image in Array(loads.keys) where !retained.contains(image) { remove(image) }
        for entry in neighbors { _ = load(entry, mode: mode, background: true) }
    }

    func validate(against entries: [ImageEntry]) {
        let versions = Dictionary(uniqueKeysWithValues: entries.map { ($0.image, $0) })
        for (image, load) in loads where versions[image] != load.entry {
            remove(image, matching: load)
        }
    }

    func setDecodeMode(_ mode: ImageDecodeMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        removeAll()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            // Keep only foreground work that is still running; image() releases
            // it on completion. ImageDocument owns the displayed image itself.
            for (image, load) in loads where load.isBackground || load.isFinished {
                remove(image, matching: load)
            }
        }
    }

    func removeAll() {
        loads.values.forEach { $0.task.cancel() }
        loads.removeAll()
    }

    private func load(_ entry: ImageEntry, mode: ImageDecodeMode, background: Bool) -> Load {
        if let existing = loads[entry.image], existing.entry == entry, !existing.task.isCancelled {
            if !background {
                existing.isBackground = false
                promote(existing.id)
            }
            return existing
        }
        remove(entry.image)
        let load = Load(entry: entry, isBackground: background)
        let loader = loader
        // Read isBackground when the task actually starts, so promotion also
        // works if navigation arrives before the transfer has entered the queue.
        load.task = Task { [weak load] in
            guard let load else { throw CancellationError() }
            defer { load.isFinished = true }
            try Task.checkCancellation()
            return try await loader(entry.image, mode, load.id, load.isBackground)
        }
        loads[entry.image] = load
        return load
    }

    private func remove(_ image: ImageReference, matching load: Load? = nil) {
        guard let existing = loads[image], load == nil || existing === load else { return }
        existing.task.cancel()
        loads.removeValue(forKey: image)
    }
}
