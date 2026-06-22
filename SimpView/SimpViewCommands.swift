import AppKit
import SwiftUI

struct SimpViewCommands: Commands {
    @ObservedObject private var windowManager = WindowManager.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                windowManager.openImage()
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut("o")

            Menu {
                ForEach(
                    windowManager.recentDocumentURLs,
                    id: \.self
                ) { url in
                    Button {
                        windowManager.openRecentDocument(url)
                    } label: {
                        Label {
                            Text(url.lastPathComponent)
                        } icon: {
                            Image(
                                nsImage: NSWorkspace.shared.icon(
                                    forFile: url.path
                                )
                            )
                        }
                    }
                }

                Divider()

                Button {
                    windowManager.clearRecentDocuments()
                } label: {
                    Label("Clear Menu", systemImage: "trash")
                }
                .disabled(windowManager.recentDocumentURLs.isEmpty)
            } label: {
                Label(
                    "Open Recent",
                    systemImage: "clock.arrow.circlepath"
                )
            }

            Divider()

            Button {
                windowManager.newWindow()
            } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }
            .keyboardShortcut("n")

            Button {
                windowManager.closeActiveWindow()
            } label: {
                Label("Close Window", systemImage: "xmark")
            }
            .keyboardShortcut("w")
            .disabled(!windowManager.hasOpenWindows)
            .modifierKeyAlternate(.option) {
                Button {
                    windowManager.closeAllWindows()
                } label: {
                    Label("Close All", systemImage: "xmark.square")
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(!windowManager.hasOpenWindows)
            }
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button {
                windowManager.showInFinder()
            } label: {
                Label("Show in Finder", systemImage: "finder")
            }
            .disabled(windowManager.activeImageURL == nil)
        }

        CommandGroup(replacing: .saveItem) {
        }

        CommandMenu("Go") {
            Button {
                windowManager.previousImage()
            } label: {
                Label("Previous Image", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(windowManager.activeImageURL == nil)

            Button {
                windowManager.nextImage()
            } label: {
                Label("Next Image", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(windowManager.activeImageURL == nil)
        }

        CommandGroup(before: .toolbar) {
            Toggle(
                isOn: Binding(
                    get: { windowManager.activeZoomToFit },
                    set: { windowManager.setZoomToFit($0) }
                )
            ) {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("9")
            .disabled(windowManager.activeImageURL == nil)

            Toggle(
                isOn: Binding(
                    get: { windowManager.activeZoomToFill },
                    set: { windowManager.setZoomToFill($0) }
                )
            ) {
                Label("Zoom to Fill", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .keyboardShortcut("8")
            .disabled(windowManager.activeImageURL == nil)

            Button {
                windowManager.actualSize()
            } label: {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .keyboardShortcut("0")
            .disabled(windowManager.activeImageURL == nil)

            Button {
                windowManager.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+")
            .disabled(windowManager.activeImageURL == nil)

            Button {
                windowManager.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-")
            .disabled(windowManager.activeImageURL == nil)

            Divider()
        }
    }
}
