import CoreGraphics
import Foundation

actor ImagePreloadCache {
    private struct FileVersion: Equatable {
        let modificationDate: Date
        let fileSize: Int
    }

    private struct Load {
        let version: FileVersion
        let task: Task<CGImage?, Never>
    }

    private var loads: [URL: Load] = [:]
    private var currentURL: URL?
    private var previousCurrentURL: URL?
    private var adjacentURLs: Set<URL> = []
    private var foregroundLoadCounts: [URL: Int] = [:]
    private var isEnabled = true

    func image(at url: URL) async -> CGImage? {
        foregroundLoadCounts[url, default: 0] += 1
        defer {
            finishForegroundLoad(at: url)
        }

        previousCurrentURL = currentURL
        currentURL = url
        prune()

        while isRetained(url) {
            let version = await Self.fileVersion(for: url)
            guard isRetained(url) else {
                return nil
            }

            let image = await load(
                url,
                version: version
            ).value
            guard isRetained(url) else {
                return nil
            }

            let currentVersion = await Self.fileVersion(for: url)
            if currentVersion == version {
                return image
            }
        }

        return nil
    }

    func updateNeighborhood(
        currentURL: URL,
        adjacentImages: [FolderNavigator.ImageReference]
    ) {
        guard isEnabled else {
            return
        }
        guard self.currentURL == nil || self.currentURL == currentURL else {
            return
        }

        self.currentURL = currentURL
        previousCurrentURL = nil
        adjacentURLs = Set(adjacentImages.map(\.url))
        prune()

        for image in adjacentImages {
            _ = load(
                image.url,
                version: FileVersion(
                    modificationDate: image.modificationDate,
                    fileSize: image.fileSize
                )
            )
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            // The displayed file may have changed while caching was off.
            // Let the next neighborhood update establish fresh state.
            currentURL = nil
            previousCurrentURL = nil
            adjacentURLs.removeAll()
            return
        }

        previousCurrentURL = nil
        adjacentURLs.removeAll()
        let evictedURLs = loads.keys.filter {
            foregroundLoadCounts[$0] == nil
        }
        evict(evictedURLs)
    }

    func removeAll() {
        loads.values.forEach { $0.task.cancel() }
        loads.removeAll()
        currentURL = nil
        previousCurrentURL = nil
        adjacentURLs.removeAll()
        foregroundLoadCounts.removeAll()
    }

    private func load(
        _ url: URL,
        version: FileVersion
    ) -> Task<CGImage?, Never> {
        if let existing = loads[url] {
            if existing.version == version {
                return existing.task
            }
            existing.task.cancel()
        }

        let task = Task<CGImage?, Never>.detached(
            priority: .userInitiated
        ) {
            guard !Task.isCancelled else {
                return nil
            }
            return ImageDocument.decodeImage(at: url)
        }
        loads[url] = Load(
            version: version,
            task: task
        )
        return task
    }

    private func prune() {
        let evictedURLs = loads.keys.filter {
            !isRetained($0)
        }
        evict(evictedURLs)
    }

    private func evict(_ urls: [URL]) {
        for url in urls {
            loads[url]?.task.cancel()
            loads.removeValue(forKey: url)
        }
    }

    private func isRetained(_ url: URL) -> Bool {
        foregroundLoadCounts[url] != nil
            || url == currentURL
            || url == previousCurrentURL
            || adjacentURLs.contains(url)
    }

    private func finishForegroundLoad(at url: URL) {
        guard let count = foregroundLoadCounts[url] else {
            return
        }

        if count > 1 {
            foregroundLoadCounts[url] = count - 1
        } else {
            foregroundLoadCounts.removeValue(forKey: url)
        }

        if !isEnabled, foregroundLoadCounts[url] == nil {
            evict([url])
        }
    }

    nonisolated private static func fileVersion(
        for url: URL
    ) async -> FileVersion {
        await Task.detached(priority: .userInitiated) {
            let values = try? url.resourceValues(
                forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                ]
            )
            return FileVersion(
                modificationDate:
                    values?.contentModificationDate ?? .distantPast,
                fileSize: values?.fileSize ?? -1
            )
        }.value
    }
}
