import AppKit
import Combine
import Foundation

// Standalone regression checks; no camera, app launch, or user preferences needed.
@main
struct CameraNavigationTests {
    @MainActor
    static func main() async throws {
        try await cancellationAndOrdering()
        try await shortReadsAndDisconnect()
        try await preloadPriority()
        try await cameraCaching()
        try await navigationAndLoading()
        try await filesystemBrowsing()
        print("Camera queue, navigation, and document checks passed")
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Async test did not reach expected state")
    }

    @MainActor
    private static func cancellationAndOrdering() async throws {
        let queue = CameraReadQueue()
        let gate = ReadGate()
        let first = Task { try await queue.data(size: 8 * 1_048_576, read: gate.read) }
        await waitUntil { gate.offsets.count == 1 }
        precondition(gate.lengths == [4 * 1_048_576])
        var secondStarted = false
        let second = Task {
            try await queue.data(size: 3) { _, _ in
                secondStarted = true
                return Data([1, 2, 3])
            }
        }
        let queuedCancellation = Task {
            try await queue.data(size: 1) { _, _ in
                preconditionFailure("Cancelled queued request must not read")
            }
        }
        await Task.yield()
        queuedCancellation.cancel()
        first.cancel()
        do { _ = try await first.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError {}
        do { _ = try await queuedCancellation.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError {}
        precondition(!secondStarted, "A cancelled outstanding read must still drain before another read starts")
        gate.complete(Data(repeating: 0, count: 4 * 1_048_576))
        let result = try await second.value
        precondition(result == Data([1, 2, 3]))
        precondition(gate.offsets == [0], "Cancellation must prevent the next chunk")
    }

    @MainActor
    private static func shortReadsAndDisconnect() async throws {
        let queue = CameraReadQueue()
        var offsets: [Int] = []
        let result = try await queue.data(size: 9) { offset, _ in
            offsets.append(offset)
            return Data(repeating: UInt8(offset), count: 3)
        }
        precondition(offsets == [0, 3, 6] && result.count == 9)
        do {
            _ = try await queue.data(size: 1) { _, _ in Data() }
            preconditionFailure("Empty read must fail, not loop")
        } catch CameraError.invalidData {}

        let gate = ReadGate()
        let active = Task { try await queue.data(size: 10, read: gate.read) }
        await waitUntil { gate.offsets.count == 1 }
        let waiting = Task { try await queue.data(size: 1) { _, _ in Data([1]) } }
        // Ensure the task has entered the queue before invalidating it.
        for _ in 0..<10 { await Task.yield() }
        queue.invalidate()
        do { _ = try await active.value; preconditionFailure("Expected disconnect") }
        catch CameraError.disconnected {}
        do { _ = try await waiting.value; preconditionFailure("Expected disconnect") }
        catch CameraError.disconnected {}
        gate.complete(Data([0])) // A late callback must not resume anyone twice.
    }

    @MainActor
    private static func preloadPriority() async throws {
        let queue = CameraReadQueue()
        let gate = ReadGate()
        let backgroundID = UUID()
        let background = Task {
            try await queue.data(id: backgroundID, size: 8 * 1_048_576, isBackground: true, read: gate.read)
        }
        await waitUntil { gate.offsets.count == 1 }
        var foregroundFinished = false
        let foreground = Task {
            try await queue.data(size: 1) { _, _ in
                foregroundFinished = true
                return Data([7])
            }
        }
        for _ in 0..<10 { await Task.yield() }
        gate.complete(Data(repeating: 0, count: 4 * 1_048_576))
        await waitUntil { gate.offsets.count == 2 }
        precondition(foregroundFinished, "Foreground must run between preload chunks")
        precondition(gate.offsets == [0, 4 * 1_048_576], "Paused preload must keep partial bytes")
        gate.complete(Data(repeating: 0, count: 4 * 1_048_576))
        _ = try await foreground.value
        _ = try await background.value

        let blocker = ReadGate()
        let active = Task { try await queue.data(size: 1, read: blocker.read) }
        await waitUntil { blocker.offsets.count == 1 }
        var order: [Int] = []
        let first = Task { try await queue.data(size: 1, isBackground: true) { _, _ in order.append(1); return Data([1]) } }
        let id = UUID()
        let second = Task { try await queue.data(id: id, size: 1, isBackground: true) { _, _ in order.append(2); return Data([2]) } }
        for _ in 0..<10 { await Task.yield() }
        queue.promote(id)
        blocker.complete(Data([0]))
        _ = try await active.value
        _ = try await first.value
        _ = try await second.value
        precondition(order == [2, 1], "Joining a queued preload must promote it")
    }

    @MainActor
    private static func cameraCaching() async throws {
        let session = UUID()
        let entries = (0..<4).map { i in
            ImageEntry(image: .camera(session: session, item: UUID(), name: "\(i).jpg", path: "\(i).jpg"),
                       modificationDate: .distantPast, fileSize: 10)
        }
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let decoded = context.makeImage()!
        var counts: [ImageReference: Int] = [:]
        var gate: CheckedContinuation<Void, Never>?
        var promotions = 0
        let cache = CameraImageCache(loader: { image, _, _, _ in
            counts[image, default: 0] += 1
            if image == entries[2].image, counts[image] == 1 {
                await withCheckedContinuation { gate = $0 }
            }
            return decoded
        }, promote: { _ in promotions += 1 })
        _ = try await cache.image(entries[1], mode: .standard)
        cache.updateNeighborhood(current: entries[1].image, neighbors: [entries[0], entries[2]], mode: .standard)
        await waitUntil { gate != nil && counts[entries[0].image] == 1 }
        let next = Task { try await cache.image(entries[2], mode: .standard) }
        await waitUntil { promotions == 1 }
        gate?.resume(); gate = nil
        _ = try await next.value
        precondition(counts[entries[2].image] == 1, "Navigation must share in-flight preload")
        cache.updateNeighborhood(current: entries[2].image, neighbors: [entries[1], entries[3]], mode: .standard)
        _ = try await cache.image(entries[1], mode: .standard)
        precondition(counts[entries[1].image] == 1, "Previous current image must stay cached")
        _ = try await cache.image(entries[0], mode: .standard)
        precondition(counts[entries[0].image] == 2, "Old neighbor must be evicted")
        let changed = ImageEntry(image: entries[0].image, modificationDate: .now, fileSize: 11)
        _ = try await cache.image(changed, mode: .standard)
        precondition(counts[entries[0].image] == 3, "Changed metadata must invalidate image")
        _ = try await cache.image(changed, mode: .hdr)
        precondition(counts[entries[0].image] == 4, "Decode mode must invalidate image")
        cache.setEnabled(false)
        _ = try await cache.image(changed, mode: .hdr)
        _ = try await cache.image(changed, mode: .hdr)
        precondition(counts[entries[0].image] == 6, "Disabled cache must not retain images")
        cache.removeAll()

        var started = false
        var cancelled = false
        let cancellable = CameraImageCache(loader: { _, _, _, _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
            return decoded
        }, promote: { _ in })
        let foreground = Task { try await cancellable.image(entries[0], mode: .standard) }
        await waitUntil { started }
        foreground.cancel()
        do { _ = try await foreground.value; preconditionFailure("Expected cancelled load") }
        catch is CancellationError {}
        precondition(cancelled, "Cancelling foreground must propagate to the transfer")

        started = false
        cancelled = false
        let closing = Task { try await cancellable.image(entries[0], mode: .standard) }
        await waitUntil { started }
        cancellable.setEnabled(false)
        precondition(!cancelled, "Disabling preloads must not cancel foreground work")
        cancellable.removeAll()
        do { _ = try await closing.value; preconditionFailure("Expected cancelled load") }
        catch is CancellationError {}
        precondition(cancelled, "Closing source must cancel outstanding work")
    }

    @MainActor
    private static func navigationAndLoading() async throws {
        let defaults = UserDefaults(suiteName: "SimpView.tests.\(UUID())")!
        let prefs = AppPreferences(defaults: defaults)
        let source = TestSource()
        let session = UUID()
        let a = ImageReference.camera(session: session, item: UUID(), name: "same.jpg", path: "A/same.jpg")
        let b = ImageReference.camera(session: session, item: UUID(), name: "same.jpg", path: "B/same.jpg")
        source.list = [a, b].map { ImageEntry(image: $0, modificationDate: .distantPast, fileSize: 10) }
        let navigator = ImageNavigator(source: source, preferences: prefs)
        navigator.prepareForExternalOpen(a)
        let next = await navigator.navigationImage(from: a, target: .relative(offset: 1, clampsToBounds: false))
        precondition(next == b && source.listCount == 1)
        precondition(navigator.position(of: b)?.count == 2)
        precondition(navigator.adjacentImages(to: a).map(\.image) == [b])
        let end = await navigator.navigationImage(from: b, target: .relative(offset: 1, clampsToBounds: false))
        precondition(end == nil)
        let jump = await navigator.navigationImage(from: a, target: .relative(offset: 100, clampsToBounds: true))
        precondition(jump == b)
        let random = await navigator.navigationImage(from: a, target: .random)
        precondition(random == b)
        navigator.markListingDirty() // Camera source ignores focus changes.
        _ = await navigator.navigationImage(from: a, target: .endpoint(first: false))
        precondition(source.listCount == 1)
        source.invalidations.send()
        _ = await navigator.navigationImage(from: a, target: .endpoint(first: false))
        precondition(source.listCount == 2)
        navigator.close()

        let document = ImageDocument()
        let gate = ReadGate()
        let slow = Task {
            await document.open(resolvingImage: { a }, decode: { _ in
                _ = try await gate.read(0, 1)
                return nil
            })
        }
        await waitUntil { document.reference == a }
        precondition(document.isLoading && !document.isShowingLoadingIndicator && document.fileURL == nil)
        let failure = await document.open(resolvingImage: { b }, decode: { _ in throw CameraError.missingFile })
        guard case .failed(let failed) = failure, failed == b else { preconditionFailure("Expected non-modal error") }
        gate.complete(Data([0]))
        guard case .superseded = await slow.value else { preconditionFailure("Old result must be ignored") }
        precondition(document.reference == b && document.hasDecodeError && !document.isLoading)
        precondition(document.errorMessage == CameraError.missingFile.localizedDescription)
        document.close()
    }

    @MainActor
    private static func filesystemBrowsing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.png")
        let b = directory.appendingPathComponent("b.png")
        let context = CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: a)
        let defaults = UserDefaults(suiteName: "SimpView.tests.\(UUID())")!
        let prefs = AppPreferences(defaults: defaults)
        let source = FileImageSource()
        let navigator = ImageNavigator(source: source, preferences: prefs)
        let current = ImageReference.file(a.standardizedFileURL)
        navigator.prepareForExternalOpen(current)
        let end = await navigator.navigationImage(from: current, target: .endpoint(first: false))
        let initialList = await source.entries(for: current)
        precondition(end == nil && navigator.position(of: current)?.count == 1,
                     "end=\(String(describing: end)), current=\(current), position=\(String(describing: navigator.position(of: current))), listed=\(initialList)")
        try png.write(to: b)
        let listed = await source.entries(for: current)
        precondition(listed.count == 2, "Filesystem backend returned \(listed); PNG supported=\(SupportedImages.contains(filename: "a.png")); directory=\(directory)")
        navigator.markListingDirty()
        let next = await navigator.navigationImage(from: current, target: .relative(offset: 1, clampsToBounds: false))
        precondition(next?.fileURL?.standardizedFileURL == b.standardizedFileURL && navigator.position(of: next)?.count == 2,
                     "next=\(String(describing: next)), expected=\(b.standardizedFileURL), position=\(String(describing: navigator.position(of: next)))")
        let decoded = try await source.load(current, mode: .standard)
        precondition(decoded?.width == 2 && decoded?.height == 3)
        let memoryDecoded = ImageDocument.decodeImage(data: png, mode: .standard)
        precondition(memoryDecoded?.width == decoded?.width && memoryDecoded?.height == decoded?.height)
        let copy = directory.appendingPathComponent("saved.png")
        let dates = ImageFileDates(creation: Date(timeIntervalSince1970: 1_600_000_000),
                                  modification: Date(timeIntervalSince1970: 1_600_000_100))
        try dates.apply(to: a)
        try Data([1, 2, 3]).write(to: copy)
        try await source.saveCopy(current, to: copy)
        let saved = try Data(contentsOf: copy)
        precondition(saved == png, "Save a Copy must preserve the original bytes and replace existing contents")
        let savedDates = try copy.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        precondition(savedDates.creationDate == dates.creation && savedDates.contentModificationDate == dates.modification,
                     "Save a Copy must preserve creation and modification dates: \(savedDates)")
        navigator.close()
    }
}

@MainActor
private final class ReadGate {
    var offsets: [Int] = []
    var lengths: [Int] = []
    private var continuation: CheckedContinuation<Data, Error>?
    func read(_ offset: Int, _ length: Int) async throws -> Data {
        offsets.append(offset)
        lengths.append(length)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@MainActor
private final class TestSource: ImageSource {
    let invalidations = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { invalidations.eraseToAnyPublisher() }
    let isAvailable = true
    let refreshesOnActivation = false
    var list: [ImageEntry] = []
    var listCount = 0
    func entries(for image: ImageReference) async -> [ImageEntry] { listCount += 1; return list }
    func load(_ image: ImageReference, mode: ImageDecodeMode) async throws -> CGImage? { nil }
    func saveCopy(_ image: ImageReference, to destination: URL) async throws { throw CocoaError(.featureUnsupported) }
    func close() {}
}
