import AppKit
import SwiftUI

@MainActor
final class CameraPicker: NSWindowController {
    private let model = CameraPickerModel()

    init(open: @escaping (ImageReference, CameraSession) -> Void, dismiss: @escaping () -> Void) {
        super.init(window: nil)
        let view = CameraPickerView(model: model) { [weak self] image, session in
            open(image, session)
            self?.finish()
            dismiss()
        } cancel: { [weak self] in
            self?.finish()
            dismiss()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Open Camera"
        window.styleMask = [.titled, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 550, height: 360)
        window.isReleasedWhenClosed = false
        self.window = window
        CameraBrowser.shared.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func finish() {
        model.select(nil)
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
    }
}

@MainActor
final class CameraPickerModel: ObservableObject {
    @Published private(set) var source: CameraImageSource?

    func select(_ session: CameraSession?) {
        guard source?.session !== session else { return }
        source?.close()
        source = session.map { CameraImageSource(session: $0) }
    }
}

private struct CameraPickerView: View {
    @ObservedObject var model: CameraPickerModel
    @ObservedObject private var browser = CameraBrowser.shared
    @State private var selectedDevice: UUID?
    let open: (ImageReference, CameraSession) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Camera", selection: $selectedDevice) {
                Text("Select a camera").tag(Optional<UUID>.none)
                ForEach(browser.sessions) { Text($0.name).tag(Optional($0.id)) }
            }
            if let source = model.source {
                CameraContentsView(session: source.session, open: open, cancel: cancel)
                    .id(source.session.id)
            } else {
                ContentUnavailableView("Connect a Camera", systemImage: "camera", description: Text("Connect and turn on your camera, then select it above."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction) }
            }
        }
        .padding(20)
        .onChange(of: selectedDevice) { _, id in
            model.select(browser.sessions.first { $0.id == id })
        }
        .onChange(of: browser.sessions.map(\.id), initial: true) { _, ids in
            if selectedDevice == nil || !ids.contains(selectedDevice!) { selectedDevice = ids.first }
        }
    }
}

private struct CameraContentsView: View {
    @ObservedObject var session: CameraSession
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var selection: ImageReference?
    @State private var sortedEntries: [ImageEntry] = []
    @State private var hasSelectedInitialImage = false
    let open: (ImageReference, CameraSession) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.status).foregroundStyle(.secondary)
            if session.isReady {
                ScrollViewReader { proxy in
                    Table(sortedEntries, selection: $selection) {
                        TableColumn("Image") { Text($0.image.name) }
                        TableColumn("Camera Path") { Text($0.image.path) }
                    }
                    .task(id: selection) {
                        if let selection {
                            proxy.scrollTo(selection)
                        }
                    }
                }
            } else if session.isConnecting {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Button("Try Again") { session.retry() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Browse all supported images on this camera. Camera images are not included in saved sessions.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let entry = sortedEntries.first(where: { $0.image == selection }) {
                        open(entry.image, session)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.isReady || selection == nil || !sortedEntries.contains { $0.image == selection })
            }
        }
        .task(id: SortRequest(entries: session.entries, field: preferences.imageSortField, direction: preferences.imageSortDirection)) {
            let entries = session.entries
            let field = preferences.imageSortField
            let direction = preferences.imageSortDirection
            let result = await Task.detached { ImageEntry.sorted(entries, field: field, direction: direction) }.value
            guard !Task.isCancelled else { return }
            sortedEntries = result
            if !hasSelectedInitialImage, !result.isEmpty {
                selection = result.max { left, right in
                    if left.modificationDate != right.modificationDate {
                        return left.modificationDate < right.modificationDate
                    }
                    // Burst photos can share a timestamp; prefer the later filename.
                    let nameOrder = left.image.name.localizedStandardCompare(right.image.name)
                    return nameOrder == .orderedSame
                        ? left.image.path.compare(right.image.path) == .orderedAscending
                        : nameOrder == .orderedAscending
                }?.image
                hasSelectedInitialImage = true
            }
        }
    }

    private struct SortRequest: Equatable {
        let entries: [ImageEntry]
        let field: ImageSortField
        let direction: SortDirection
    }
}
