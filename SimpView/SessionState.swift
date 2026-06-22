import Foundation

struct SessionState: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let windows: [SessionWindowState]
}

struct SessionWindowState: Codable {
    let frame: SessionRect
    let imagePath: String?
    let viewport: ViewportSessionState?
    let isKeyWindow: Bool
    let isMiniaturized: Bool
}

struct ViewportSessionState: Codable {
    let zoomMode: ViewportZoomMode
    let magnification: Double
    // Image-space viewport center, normalized to the image dimensions.
    let centerX: Double
    let centerY: Double
}

struct SessionRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum SessionStateStore {
    enum LoadResult {
        case none
        case loaded(SessionState)
        case unsupportedVersion
    }

    private struct Header: Decodable {
        let formatVersion: Int
    }

    static func load() -> LoadResult {
        guard
            let data = try? Data(contentsOf: fileURL),
            let header = try? JSONDecoder().decode(
                Header.self,
                from: data
            )
        else {
            return .none
        }

        guard header.formatVersion == SessionState.currentFormatVersion else {
            return .unsupportedVersion
        }

        guard
            let state = try? JSONDecoder().decode(
                SessionState.self,
                from: data
            )
        else {
            return .none
        }

        return .loaded(state)
    }

    static func save(_ state: SessionState) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    static func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static var fileURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportURL
            .appendingPathComponent("SimpView", isDirectory: true)
            .appendingPathComponent("Session.json", isDirectory: false)
    }
}
