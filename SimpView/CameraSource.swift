import AppKit
import Combine
import ImageCaptureCore
import ImageIO

@MainActor
final class CameraBrowser: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate {
    static let shared = CameraBrowser()
    @Published private(set) var sessions: [CameraSession] = []
    private let browser = ICDeviceBrowser()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.start()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        sessions.append(CameraSession(device: camera))
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        sessions.filter { $0.device === device }.forEach { $0.disconnected() }
        sessions.removeAll { $0.device === device }
    }
}

// ImageCaptureCore delegates deliver on the main thread. Its completion-block
// read API can deliver on any queue and is bridged to async below.
@MainActor
final class CameraSession: NSObject, ObservableObject, Identifiable, @preconcurrency ICCameraDeviceDelegate {
    let id = UUID()
    let device: ICCameraDevice
    var name: String { device.name ?? "Camera" }
    @Published private(set) var entries: [ImageEntry] = []
    @Published private(set) var status = "Opening camera…"
    @Published private(set) var isReady = false
    let changes = PassthroughSubject<Void, Never>()

    private var clients: Set<UUID> = []
    @Published private var state: State = .closed
    var isConnecting: Bool { state == .opening }
    private enum State { case closed, opening, ready, closing, disconnected }
    private var files: [UUID: ICCameraFile] = [:]
    private var itemIDs: [ObjectIdentifier: UUID] = [:]
    private var catalogueUpdate: Task<Void, Never>?
    private var reads = CameraReadQueue()

    init(device: ICCameraDevice) {
        self.device = device
        super.init()
        device.delegate = self
    }

    func acquire() -> UUID {
        let client = UUID()
        clients.insert(client)
        if state == .closed { openSession() }
        return client
    }

    func release(_ client: UUID) {
        clients.remove(client)
        guard clients.isEmpty, state == .ready || state == .opening else { return }
        if state == .ready { closeSession() }
        // An opening session is closed as soon as its open callback arrives.
    }

    private func openSession() {
        state = .opening
        status = "Opening camera…"
        device.requestOpenSession()
    }

    func retry() {
        if state == .closed, !clients.isEmpty { openSession() }
    }

    private func closeSession() {
        state = .closing
        isReady = false
        catalogueUpdate?.cancel()
        reads.invalidate()
        device.requestCloseSession()
    }

    func disconnected() {
        guard state != .disconnected else { return }
        state = .disconnected
        isReady = false
        status = "Camera disconnected. Reconnect it and choose Open Camera again."
        catalogueUpdate?.cancel()
        reads.invalidate()
        changes.send()
    }

    func promoteRead(_ id: UUID) { reads.promote(id) }

    func fileDates(for image: ImageReference) throws -> ImageFileDates {
        guard case .camera(let session, let id, _, _) = image,
              session == self.id, let file = files[id] else { throw CameraError.missingFile }
        return ImageFileDates(creation: file.fileCreationDate, modification: file.fileModificationDate)
    }

    func load(_ image: ImageReference, mode: ImageDecodeMode, requestID: UUID = UUID(), isBackground: Bool = false) async throws -> CGImage? {
        let data = try await readData(image, requestID: requestID, isBackground: isBackground)
        let decode = Task.detached(priority: isBackground ? .utility : .userInitiated) {
            guard !Task.isCancelled else { return nil as CGImage? }
            return ImageDocument.decodeImage(data: data, mode: mode)
        }
        return await withTaskCancellationHandler {
            await decode.value
        } onCancel: {
            decode.cancel()
        }
    }

    func readData(_ image: ImageReference, requestID: UUID = UUID(), isBackground: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard state == .ready else { throw CameraError.disconnected }
        guard case .camera(let session, let id, _, _) = image,
              session == self.id, let file = files[id] else { throw CameraError.missingFile }
        guard file.fileSize > 0, file.fileSize <= Int.max else { throw CameraError.invalidData }
        let data = try await reads.data(id: requestID, size: Int(file.fileSize), isBackground: isBackground) { offset, length in
            try await withCheckedThrowingContinuation { continuation in
                file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: CameraError.invalidData) }
                }
            }
        }
        try Task.checkCancellation()
        return data
    }

    private func updateCatalogue() {
        var entries: [ImageEntry] = []
        var files: [UUID: ICCameraFile] = [:]
        var ids: [ObjectIdentifier: UUID] = [:]
        for case let file as ICCameraFile in device.mediaFiles ?? [] {
            let name = file.name ?? file.originalFilename ?? ""
            guard SupportedImages.contains(filename: name) else { continue }
            let objectID = ObjectIdentifier(file)
            let id = itemIDs[objectID] ?? UUID()
            ids[objectID] = id
            files[id] = file
            var parts = [name]
            var parent = file.parentFolder
            while let folder = parent {
                parts.insert(folder.name ?? "", at: 0)
                parent = folder.parentFolder
            }
            entries.append(ImageEntry(
                image: .camera(session: self.id, item: id, name: name, path: parts.joined(separator: "/")),
                modificationDate: file.fileModificationDate ?? .distantPast,
                fileSize: Int(clamping: file.fileSize)
            ))
        }
        self.files = files
        itemIDs = ids
        self.entries = entries
        changes.send()
    }

    private func catalogueChanged() {
        guard state == .ready else { return }
        // Batch event bursts; initial enumeration is handled once on completion.
        guard catalogueUpdate == nil else { return }
        catalogueUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            catalogueUpdate = nil
            updateCatalogue()
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard state == .opening else { return }
        if let error {
            state = .closed
            status = error.localizedDescription
            changes.send()
        } else if clients.isEmpty {
            closeSession()
        } else {
            status = "Reading camera contents…"
        }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard state != .disconnected else { return }
        state = .closed
        isReady = false
        files.removeAll()
        itemIDs.removeAll()
        entries = []
        // Late callbacks from the old queue cannot block reads in a new session.
        reads = CameraReadQueue()
        catalogueUpdate = nil
        if !clients.isEmpty { openSession() }
    }
    func didRemove(_ device: ICDevice) { disconnected() }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard state == .opening else { return }
        if clients.isEmpty { closeSession(); return }
        state = .ready
        updateCatalogue()
        isReady = true
        status = entries.isEmpty ? "No supported images on this camera." : "\(entries.count) images"
        changes.send()
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        if state == .opening { status = "Reading camera contents… \(camera.contentCatalogPercentCompleted)%" }
        catalogueChanged()
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { catalogueChanged() }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { catalogueChanged() }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { status = "Reading camera contents…" }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { status = "Unlock the camera to access its images." }
}

@MainActor
final class CameraImageSource: ImageSource {
    let session: CameraSession
    private var client: UUID?
    private let cache: CameraImageCache
    private var catalogueObserver: AnyCancellable?
    var changes: AnyPublisher<Void, Never> { session.changes.eraseToAnyPublisher() }
    var isAvailable: Bool { session.isReady }
    let refreshesOnActivation = false

    init(session: CameraSession) {
        self.session = session
        cache = CameraImageCache(
            loader: { try await session.load($0, mode: $1, requestID: $2, isBackground: $3) },
            promote: { session.promoteRead($0) }
        )
        client = session.acquire()
        catalogueObserver = session.changes.sink { [weak self] in
            guard let self else { return }
            if session.isReady { cache.validate(against: session.entries) }
            else { cache.removeAll() }
        }
    }
    func entries(for image: ImageReference) async -> [ImageEntry] { session.entries }
    func load(_ image: ImageReference, mode: ImageDecodeMode) async throws -> CGImage? {
        guard session.isReady else { throw CameraError.disconnected }
        guard let entry = session.entries.first(where: { $0.image == image }) else { throw CameraError.missingFile }
        cache.setEnabled(AppPreferences.shared.preloadAdjacentImages)
        return try await cache.image(entry, mode: mode)
    }
    func preload(current: ImageReference, neighbors: [ImageEntry], mode: ImageDecodeMode) async {
        guard session.isReady, client != nil else { return }
        cache.updateNeighborhood(current: current, neighbors: neighbors, mode: mode)
    }
    func saveCopy(_ image: ImageReference, to destination: URL) async throws {
        let client = session.acquire()
        defer { session.release(client) }
        let dates = try session.fileDates(for: image)
        let data = try await session.readData(image)
        let write = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
            try dates.apply(to: destination)
        }
        try await withTaskCancellationHandler {
            try await write.value
        } onCancel: {
            write.cancel()
        }
    }
    func setPreloadingEnabled(_ enabled: Bool) async { cache.setEnabled(enabled) }
    func setDecodeMode(_ mode: ImageDecodeMode) async { cache.setDecodeMode(mode) }
    func close() {
        catalogueObserver = nil
        cache.removeAll()
        if let client { session.release(client); self.client = nil }
    }
}
