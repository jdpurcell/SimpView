import Foundation

enum CameraError: LocalizedError {
    case disconnected, missingFile, invalidData

    var errorDescription: String? {
        switch self {
        case .disconnected: "The camera is disconnected or its session is closed."
        case .missingFile: "This image is no longer available on the camera."
        case .invalidData: "The camera returned incomplete or invalid image data."
        }
    }
}

// One queue per camera. Cancellation releases the waiting window immediately,
// but the queue waits for the outstanding read before serving another window.
// The read closure also makes the ordering/cancellation behavior testable without
// a physical camera.
@MainActor
final class CameraReadQueue {
    typealias Read = @MainActor (Int, Int) async throws -> Data

    private final class Request {
        let id: UUID
        let size: Int
        let read: Read
        var isBackground: Bool
        var data = Data()
        var continuation: CheckedContinuation<Data, Error>?

        init(id: UUID, size: Int, isBackground: Bool, read: @escaping Read, continuation: CheckedContinuation<Data, Error>) {
            self.id = id
            self.size = size
            self.read = read
            self.isBackground = isBackground
            self.continuation = continuation
        }

        func finish(_ result: Result<Data, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private var waiting: [Request] = []
    private var active: Request?
    private var worker: Task<Void, Never>?

    func data(id: UUID = UUID(), size: Int, isBackground: Bool = false, read: @escaping Read) async throws -> Data {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append(Request(id: id, size: size, isBackground: isBackground, read: read, continuation: continuation))
                if worker == nil {
                    worker = Task { await self.drain() }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func promote(_ id: UUID) {
        if active?.id == id { active?.isBackground = false }
        waiting.first { $0.id == id }?.isBackground = false
    }

    func invalidate() {
        active?.finish(.failure(CameraError.disconnected))
        waiting.forEach { $0.finish(.failure(CameraError.disconnected)) }
        waiting.removeAll()
    }

    private func cancel(_ id: UUID) {
        if active?.id == id { active?.finish(.failure(CancellationError())) }
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).finish(.failure(CancellationError()))
        }
    }

    private func drain() async {
        while !waiting.isEmpty {
            let index = waiting.firstIndex { !$0.isBackground } ?? waiting.startIndex
            let request = waiting.remove(at: index)
            active = request
            do {
                guard request.size > 0 else { throw CameraError.invalidData }
                while request.data.count < request.size, request.continuation != nil {
                    let count = min(4 * 1_048_576, request.size - request.data.count)
                    let chunk = try await request.read(request.data.count, count)
                    guard request.continuation != nil else { break }
                    guard !chunk.isEmpty, chunk.count <= count else { throw CameraError.invalidData }
                    if request.data.isEmpty { request.data = chunk } else { request.data.append(chunk) }
                    // Keep partial bytes, but let an explicit load use the camera
                    // before continuing a speculative transfer.
                    if request.isBackground, waiting.contains(where: { !$0.isBackground }) { break }
                }
                if request.continuation != nil {
                    if request.data.count == request.size { request.finish(.success(request.data)) }
                    else { waiting.insert(request, at: 0) }
                }
            } catch {
                request.finish(.failure(error))
            }
            active = nil
        }
        worker = nil
    }
}
