import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageNavigationCommand: Equatable {
    case previous
    case next
    case jumpBack
    case jumpForward
    case first
    case last
    case random
}

@MainActor
final class FolderNavigator {
    enum NavigationTarget {
        case relative(offset: Int, clampsToBounds: Bool)
        case endpoint(first: Bool)
        case random
    }

    struct Position: Equatable {
        let index: Int
        let count: Int
    }

    struct ImageReference: Sendable {
        let url: URL
        let modificationDate: Date
        let fileSize: Int
    }

    var listingChanged: (() -> Void)?

    private struct Entry: Sendable {
        let url: URL
        let name: String
        let modificationDate: Date
        let fileSize: Int
    }

    private struct ActiveRefresh {
        let identifier: UUID
        let directoryURL: URL
        let dirtyGeneration: Int
        let sortField: ImageSortField
        let sortDirection: SortDirection
        let task: Task<[Entry], Never>
    }

    private var directoryURL: URL?
    private var entries: [Entry] = []
    private var fallbackEntry: Entry?
    private var activeRefresh: ActiveRefresh?
    private var listingDirtyGeneration = 0
    private var listingRefreshGeneration = -1
    private var sortField: ImageSortField
    private var sortDirection: SortDirection
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(preferences: .shared)
    }

    init(preferences: AppPreferences) {
        sortField = preferences.imageSortField
        sortDirection = preferences.imageSortDirection

        preferences.$imageSortField
            .combineLatest(preferences.$imageSortDirection)
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] field, direction in
                self?.updateSort(field: field, direction: direction)
            }
            .store(in: &cancellables)
    }

    func prepareForExternalOpen(_ url: URL) {
        let normalizedURL = normalized(url)
        let newDirectoryURL = normalizedURL.deletingLastPathComponent()
        fallbackEntry = entry(for: normalizedURL)

        if directoryURL != newDirectoryURL
            || entryIndex(for: normalizedURL) == nil
        {
            directoryURL = newDirectoryURL
            entries = [fallbackEntry].compactMap { $0 }
            listingChanged?()
        }

        startBackgroundRefresh(for: newDirectoryURL)
    }

    func markListingDirty() {
        listingDirtyGeneration += 1
    }

    func navigationURL(
        from currentURL: URL,
        target: NavigationTarget
    ) async -> URL? {
        let normalizedURL = await prepareForNavigation(from: currentURL)
        guard let currentIndex = entryIndex(for: normalizedURL) else {
            return nil
        }

        switch target {
        case .relative(let offset, let clampsToBounds):
            guard offset != 0 else {
                return nil
            }

            let targetIndex = currentIndex + offset
            let resolvedIndex = clampsToBounds
                ? min(max(targetIndex, entries.startIndex), entries.endIndex - 1)
                : targetIndex
            guard
                entries.indices.contains(resolvedIndex),
                resolvedIndex != currentIndex
            else {
                return nil
            }

            return entries[resolvedIndex].url

        case .endpoint(let first):
            let targetIndex = first ? entries.startIndex : entries.endIndex - 1
            guard
                entries.indices.contains(targetIndex),
                targetIndex != currentIndex
            else {
                return nil
            }

            return entries[targetIndex].url

        case .random:
            guard entries.count > 1 else {
                return nil
            }

            var targetIndex = Int.random(in: 0..<(entries.count - 1))
            if targetIndex >= currentIndex {
                targetIndex += 1
            }

            return entries[targetIndex].url
        }
    }

    func adjacentURL(from currentURL: URL, offset: Int) async -> URL? {
        await navigationURL(
            from: currentURL,
            target: .relative(offset: offset, clampsToBounds: false)
        )
    }

    func endpointURL(from currentURL: URL, first: Bool) async -> URL? {
        await navigationURL(
            from: currentURL,
            target: .endpoint(first: first)
        )
    }

    private func prepareForNavigation(from currentURL: URL) async -> URL {
        let normalizedURL = normalized(currentURL)
        let currentDirectoryURL = normalizedURL.deletingLastPathComponent()

        let directoryChanged = directoryURL != currentDirectoryURL
        if directoryChanged {
            directoryURL = currentDirectoryURL
            fallbackEntry = entry(for: normalizedURL)
            entries = [fallbackEntry].compactMap { $0 }
            listingChanged?()
        }

        let shouldRefresh =
            directoryChanged
            || activeRefresh?.directoryURL == currentDirectoryURL
            || listingRefreshGeneration < listingDirtyGeneration

        if shouldRefresh {
            await refresh(for: currentDirectoryURL)
        }

        return normalizedURL
    }

    func didOpen(_ url: URL) {
        let openedEntry = entry(for: normalized(url))
        fallbackEntry = openedEntry

        guard entryIndex(for: openedEntry.url) == nil else {
            return
        }

        entries.append(openedEntry)
        entries = Self.sorted(
            entries,
            field: sortField,
            direction: sortDirection
        )
        listingChanged?()
    }

    func position(of url: URL?) -> Position? {
        guard let url else {
            return nil
        }

        let normalizedURL = normalized(url)
        guard let index = entryIndex(for: normalizedURL) else {
            return nil
        }

        return Position(index: index + 1, count: entries.count)
    }

    func adjacentImages(to url: URL?) -> [ImageReference] {
        guard
            let url,
            let index = entryIndex(for: normalized(url))
        else {
            return []
        }

        return [index - 1, index + 1].compactMap { neighborIndex in
            guard entries.indices.contains(neighborIndex) else {
                return nil
            }

            let entry = entries[neighborIndex]
            return ImageReference(
                url: entry.url,
                modificationDate: entry.modificationDate,
                fileSize: entry.fileSize
            )
        }
    }

    private func startBackgroundRefresh(for directoryURL: URL) {
        let refresh = startRefresh(for: directoryURL)
        Task { [weak self] in
            let refreshedEntries = await refresh.task.value
            self?.apply(
                refreshedEntries,
                for: directoryURL,
                refresh: refresh
            )
        }
    }

    private func refresh(for directoryURL: URL) async {
        repeat {
            let refresh = startRefresh(for: directoryURL)
            let refreshedEntries = await refresh.task.value
            apply(
                refreshedEntries,
                for: directoryURL,
                refresh: refresh
            )
        } while self.directoryURL == directoryURL
            && listingRefreshGeneration < listingDirtyGeneration
    }

    private func startRefresh(for directoryURL: URL) -> ActiveRefresh {
        if let activeRefresh, activeRefresh.directoryURL == directoryURL {
            return activeRefresh
        }

        activeRefresh?.task.cancel()

        let identifier = UUID()
        let sortField = sortField
        let sortDirection = sortDirection
        let task = Task.detached(priority: .userInitiated) {
            Self.sorted(
                Self.loadEntries(in: directoryURL),
                field: sortField,
                direction: sortDirection
            )
        }
        let refresh = ActiveRefresh(
            identifier: identifier,
            directoryURL: directoryURL,
            dirtyGeneration: listingDirtyGeneration,
            sortField: sortField,
            sortDirection: sortDirection,
            task: task
        )
        activeRefresh = refresh

        return refresh
    }

    private func apply(
        _ refreshedEntries: [Entry],
        for directoryURL: URL,
        refresh: ActiveRefresh
    ) {
        guard
            activeRefresh?.identifier == refresh.identifier,
            self.directoryURL == directoryURL
        else {
            return
        }

        activeRefresh = nil
        listingRefreshGeneration = max(
            listingRefreshGeneration,
            refresh.dirtyGeneration
        )
        var completeEntries = refreshedEntries
        var addedFallbackEntry = false
        let sortChanged =
            refresh.sortField != sortField
            || refresh.sortDirection != sortDirection
        if
            let fallbackEntry,
            !completeEntries.contains(
                where: { $0.name == fallbackEntry.name }
            )
        {
            completeEntries.append(fallbackEntry)
            addedFallbackEntry = true
        }
        if !completeEntries.isEmpty {
            entries = sortChanged || addedFallbackEntry
                ? Self.sorted(
                    completeEntries,
                    field: sortField,
                    direction: sortDirection
                )
                : completeEntries
        }
        listingChanged?()
    }

    private func updateSort(
        field: ImageSortField,
        direction: SortDirection
    ) {
        guard sortField != field || sortDirection != direction else {
            return
        }

        sortField = field
        sortDirection = direction
        entries = Self.sorted(
            entries,
            field: field,
            direction: direction
        )
        listingChanged?()
    }

    private func entry(for url: URL) -> Entry {
        // Fallback entries keep the UI responsive while a real folder refresh
        // gathers metadata off the main actor. Asking a network URL for file
        // size or modification date here can block session restore before the
        // loading indicator has a chance to appear.
        return Entry(
            url: url,
            name: url.lastPathComponent,
            modificationDate: .distantPast,
            fileSize: -1
        )
    }

    private func entryIndex(for url: URL) -> Int? {
        entries.firstIndex {
            $0.url == url || $0.name == url.lastPathComponent
        }
    }

    nonisolated private static func loadEntries(
        in directoryURL: URL
    ) -> [Entry] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var entries: [Entry] = []
        entries.reserveCapacity(urls.count)

        for url in urls {
            guard !Task.isCancelled else {
                break
            }

            guard
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else {
                continue
            }

            guard isImage(url) else {
                continue
            }

            entries.append(Entry(
                url: url,
                name: url.lastPathComponent,
                modificationDate:
                    values.contentModificationDate ?? .distantPast,
                fileSize: values.fileSize ?? -1
            ))
        }

        return entries
    }

    nonisolated private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }

        return supportedImageTypeIdentifiers.contains(type.identifier)
    }

    nonisolated private static let supportedImageTypeIdentifiers: Set<String> =
        Set(CGImageSourceCopyTypeIdentifiers() as! [String])

    nonisolated private static func sorted(
        _ entries: [Entry],
        field: ImageSortField,
        direction: SortDirection
    ) -> [Entry] {
        entries.sorted { left, right in
            let comparison: ComparisonResult
            switch field {
            case .name:
                comparison = left.name.localizedStandardCompare(right.name)
            case .modificationDate:
                comparison = left.modificationDate.compare(
                    right.modificationDate
                )
            }

            if comparison == .orderedSame {
                let pathComparison = left.url.path.compare(right.url.path)
                return pathComparison
                    == (direction == .ascending
                        ? .orderedAscending
                        : .orderedDescending)
            }

            return comparison
                == (direction == .ascending ? .orderedAscending : .orderedDescending)
        }
    }

    nonisolated private static func normalized(_ url: URL) -> URL {
        // Keep normalization lexical only. Resolving symlinks can touch the
        // filesystem and block badly on slow network volumes, including during
        // session restore before the loading UI has a chance to appear.
        url.standardizedFileURL
    }

    private func normalized(_ url: URL) -> URL {
        Self.normalized(url)
    }
}
