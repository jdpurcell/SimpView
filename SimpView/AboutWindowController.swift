import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    private init() {
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hostingView = NSHostingView(rootView: AboutView())
        let fittingSize = hostingView.fittingSize
        let window = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: fittingSize.width,
                height: fittingSize.height
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About \(Bundle.main.displayName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct AboutView: View {
    private let appName = Bundle.main.displayName
    private let version = Bundle.main.versionString
    private let copyright = Bundle.main.copyrightString

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .cornerRadius(16)
                .padding(.bottom, 4)

            Text(appName)
                .font(.system(size: 16, weight: .bold))

            Text("Version \(version)")
                .font(.system(size: 12, weight: .semibold))

            Text(copyright)
                .font(.system(size: 12, weight: .semibold))
        }
        .fixedSize()
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}

private extension Bundle {
    var displayName: String {
        infoDictionary?["CFBundleDisplayName"] as? String
            ?? infoDictionary?["CFBundleName"] as? String
            ?? "SimpView"
    }

    var versionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "Unknown"
    }

    var copyrightString: String {
        infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? ""
    }
}
