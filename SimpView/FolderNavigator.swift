import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class FolderNavigator {
    struct Position: Equatable {
        let index: Int
        let count: Int
    }

    var listingChanged: (() -> Void)?

    private struct Entry: Sendable {
        let url: URL
        let name: String
        let modificationDate: Date
    }

    private struct ActiveRefresh {
        let identifier: UUID
        let directoryURL: URL
        let sortField: ImageSortField
        let sortDirection: SortDirection
        let task: Task<[Entry], Never>
    }

    private static let refreshIdleInterval: TimeInterval = 2.5

    private var directoryURL: URL?
    private var entries: [Entry] = []
    private var fallbackEntry: Entry?
    private var activeRefresh: ActiveRefresh?
    private var lastImageOpenDate: Date?
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

    func adjacentURL(from currentURL: URL, offset: Int) async -> URL? {
        guard offset != 0 else {
            return nil
        }

        let normalizedURL = await prepareForNavigation(from: currentURL)
        guard let currentIndex = entryIndex(for: normalizedURL) else {
            return nil
        }

        let targetIndex = currentIndex + offset
        guard entries.indices.contains(targetIndex) else {
            return nil
        }

        return entries[targetIndex].url
    }

    func endpointURL(from currentURL: URL, first: Bool) async -> URL? {
        let normalizedURL = await prepareForNavigation(from: currentURL)
        guard let targetURL = first ? entries.first?.url : entries.last?.url,
            normalized(targetURL) != normalizedURL
        else {
            return nil
        }

        return targetURL
    }

    private func prepareForNavigation(from currentURL: URL) async -> URL {
        let normalizedURL = normalized(currentURL)
        let currentDirectoryURL = normalizedURL.deletingLastPathComponent()
        let now = Date()
        let hasBeenIdle =
            lastImageOpenDate.map {
                now.timeIntervalSince($0) >= Self.refreshIdleInterval
            } ?? true

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
            || hasBeenIdle

        if shouldRefresh {
            await refresh(for: currentDirectoryURL)
        }

        return normalizedURL
    }

    func didOpen(_ url: URL) {
        lastImageOpenDate = Date()
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
        let refresh = startRefresh(for: directoryURL)
        let refreshedEntries = await refresh.task.value
        apply(
            refreshedEntries,
            for: directoryURL,
            refresh: refresh
        )
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
        let modificationDate = (
            try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        ) ?? .distantPast

        return Entry(
            url: url,
            name: url.lastPathComponent,
            modificationDate: modificationDate
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
                    values.contentModificationDate ?? .distantPast
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
        let standardizedURL = url.standardizedFileURL
        let directoryURL = standardizedURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        return directoryURL.appendingPathComponent(
            standardizedURL.lastPathComponent,
            isDirectory: false
        )
    }

    private func normalized(_ url: URL) -> URL {
        Self.normalized(url)
    }
}
