import Combine
import Foundation

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
final class ImageNavigator {
    enum NavigationTarget {
        case relative(offset: Int, clampsToBounds: Bool)
        case endpoint(first: Bool)
        case random
    }

    struct Position: Equatable {
        let index: Int
        let count: Int
    }

    var listingChanged: (() -> Void)?
    let source: any ImageSource
    private var currentImage: ImageReference?
    private var isClosed = false

    private typealias Entry = ImageEntry

    private struct ActiveRefresh {
        let identifier: UUID
        let collectionID: String
        let dirtyGeneration: Int
        let sortField: ImageSortField
        let sortDirection: SortDirection
        let task: Task<[Entry], Never>
    }

    private var collectionID: String?
    private var entries: [Entry] = []
    private var fallbackEntry: Entry?
    private var activeRefresh: ActiveRefresh?
    private var listingDirtyGeneration = 0
    private var listingRefreshGeneration = -1
    private var sortField: ImageSortField
    private var sortDirection: SortDirection
    private var cancellables: Set<AnyCancellable> = []

    convenience init(source: any ImageSource) {
        self.init(source: source, preferences: .shared)
    }

    init(source: any ImageSource, preferences: AppPreferences) {
        self.source = source
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
        source.changes.sink { [weak self] in
            guard let self else { return }
            self.listingDirtyGeneration += 1
            self.listingChanged?()
            if let currentImage = self.currentImage { self.startBackgroundRefresh(for: currentImage.collectionID) }
        }.store(in: &cancellables)
    }

    func prepareForExternalOpen(_ image: ImageReference) {
        guard !isClosed else { return }
        currentImage = image
        let newCollectionID = image.collectionID
        fallbackEntry = entry(for: image)

        if collectionID != newCollectionID
            || entryIndex(for: image) == nil
        {
            collectionID = newCollectionID
            entries = [fallbackEntry].compactMap { $0 }
            listingChanged?()
        }

        startBackgroundRefresh(for: newCollectionID)
    }

    func markListingDirty() {
        if source.refreshesOnActivation { listingDirtyGeneration += 1 }
    }

    func navigationImage(
        from image: ImageReference,
        target: NavigationTarget
    ) async -> ImageReference? {
        await prepareForNavigation(from: image)
        guard !isClosed, !Task.isCancelled else { return nil }
        guard let currentIndex = entryIndex(for: image) else {
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

            return entries[resolvedIndex].image

        case .endpoint(let first):
            let targetIndex = first ? entries.startIndex : entries.endIndex - 1
            guard
                entries.indices.contains(targetIndex),
                targetIndex != currentIndex
            else {
                return nil
            }

            return entries[targetIndex].image

        case .random:
            guard entries.count > 1 else {
                return nil
            }

            var targetIndex = Int.random(in: 0..<(entries.count - 1))
            if targetIndex >= currentIndex {
                targetIndex += 1
            }

            return entries[targetIndex].image
        }
    }

    private func prepareForNavigation(from image: ImageReference) async {
        guard !isClosed, !Task.isCancelled else { return }
        currentImage = image
        let currentCollectionID = image.collectionID

        let directoryChanged = collectionID != currentCollectionID
        if directoryChanged {
            collectionID = currentCollectionID
            fallbackEntry = entry(for: image)
            entries = [fallbackEntry].compactMap { $0 }
            listingChanged?()
        }

        let shouldRefresh =
            directoryChanged
            || activeRefresh?.collectionID == currentCollectionID
            || listingRefreshGeneration < listingDirtyGeneration

        if shouldRefresh {
            await refresh(for: currentCollectionID)
        }
    }

    func didOpen(_ image: ImageReference) {
        currentImage = image
        let openedEntry = entry(for: image)
        fallbackEntry = openedEntry

        guard entryIndex(for: openedEntry.image) == nil else {
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

    func position(of image: ImageReference?) -> Position? {
        guard let image else {
            return nil
        }

        guard let index = entryIndex(for: image) else {
            return nil
        }

        return Position(index: index + 1, count: entries.count)
    }

    func adjacentImages(to image: ImageReference?) -> [ImageEntry] {
        guard
            let image,
            let index = entryIndex(for: image)
        else {
            return []
        }

        return [index - 1, index + 1].compactMap { neighborIndex in
            guard entries.indices.contains(neighborIndex) else {
                return nil
            }

            return entries[neighborIndex]
        }
    }

    private func startBackgroundRefresh(for collectionID: String) {
        guard !isClosed else { return }
        let refresh = startRefresh(for: collectionID)
        Task { [weak self] in
            let refreshedEntries = await refresh.task.value
            self?.apply(
                refreshedEntries,
                for: collectionID,
                refresh: refresh
            )
        }
    }

    private func refresh(for collectionID: String) async {
        repeat {
            let refresh = startRefresh(for: collectionID)
            let refreshedEntries = await refresh.task.value
            apply(
                refreshedEntries,
                for: collectionID,
                refresh: refresh
            )
        } while !isClosed && !Task.isCancelled && self.collectionID == collectionID
            && listingRefreshGeneration < listingDirtyGeneration
    }

    private func startRefresh(for collectionID: String) -> ActiveRefresh {
        if let activeRefresh, activeRefresh.collectionID == collectionID {
            return activeRefresh
        }

        activeRefresh?.task.cancel()

        let identifier = UUID()
        let sortField = sortField
        let sortDirection = sortDirection
        let source = source
        // Refreshes are only started after a collection has been established.
        let image = currentImage!
        let task = Task {
            let entries = await source.entries(for: image)
            return await Task.detached(priority: .userInitiated) {
                ImageEntry.sorted(entries, field: sortField, direction: sortDirection)
            }.value
        }
        let refresh = ActiveRefresh(
            identifier: identifier,
            collectionID: collectionID,
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
        for collectionID: String,
        refresh: ActiveRefresh
    ) {
        guard
            !isClosed,
            activeRefresh?.identifier == refresh.identifier,
            self.collectionID == collectionID
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
                where: { sameEntry($0.image, fallbackEntry.image) }
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
    private func entry(for image: ImageReference) -> Entry {
        // No synchronous filesystem metadata lookup for provisional images.
        Entry(image: image, modificationDate: .distantPast, fileSize: -1)
    }

    private func entryIndex(for image: ImageReference) -> Int? {
        entries.firstIndex { sameEntry($0.image, image) }
    }

    private func sameEntry(_ left: ImageReference, _ right: ImageReference) -> Bool {
        // FileManager can return a different spelling of the same folder (for
        // example /private/var vs /var). Entries here belong to one collection,
        // so retain the filename fallback for filesystem browsing without
        // normalizing every URL in a large listing. Camera filenames can repeat
        // across folders and must use their device/object identity instead.
        left == right || (left.fileURL != nil && right.fileURL != nil && left.name == right.name)
    }

    private static func sorted(_ entries: [Entry], field: ImageSortField, direction: SortDirection) -> [Entry] {
        ImageEntry.sorted(entries, field: field, direction: direction)
    }

    func close() {
        isClosed = true
        listingChanged = nil
        activeRefresh?.task.cancel()
        activeRefresh = nil
        cancellables.removeAll()
        source.close()
    }
}
