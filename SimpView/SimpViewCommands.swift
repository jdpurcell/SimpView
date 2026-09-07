import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SimpViewCommands: Commands {
    @ObservedObject private var windowManager = WindowManager.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SimpView") {
                AboutWindowController.shared.show()
            }
        }

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
                                    for:
                                        UTType(
                                            filenameExtension:
                                                url.pathExtension
                                        ) ?? .image
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

            Button {
                windowManager.openCamera()
            } label: {
                Label("Open Camera…", systemImage: "camera")
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
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(windowManager.activeImageURL == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button {
                windowManager.saveImageCopy()
            } label: {
                Label("Save a Copy…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!windowManager.activeCanSaveCopy)
        }

        CommandGroup(replacing: .undoRedo) {
        }

        CommandGroup(replacing: .pasteboard) {
            Button {
                windowManager.copyImageFile()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c")
            .disabled(windowManager.activeImageURL == nil)
        }

        CommandGroup(replacing: .textEditing) {
        }

        CommandMenu("Go") {
            Button {
                windowManager.previousImage()
            } label: {
                Label("Previous Image", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!windowManager.activeCanNavigate)
            .modifierKeyAlternate(.option) {
                Button {
                    windowManager.jumpBackImage()
                } label: {
                    Label("Jump Back", systemImage: "backward")
                }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .disabled(!windowManager.activeCanNavigate)
            }

            Button {
                windowManager.nextImage()
            } label: {
                Label("Next Image", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!windowManager.activeCanNavigate)
            .modifierKeyAlternate(.option) {
                Button {
                    windowManager.jumpForwardImage()
                } label: {
                    Label("Jump Forward", systemImage: "forward")
                }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .disabled(!windowManager.activeCanNavigate)
            }

            Button {
                windowManager.firstImage()
            } label: {
                Label("First Image", systemImage: "backward.end")
            }
            .keyboardShortcut(.home, modifiers: [])
            .disabled(!windowManager.activeCanNavigate)

            Button {
                windowManager.lastImage()
            } label: {
                Label("Last Image", systemImage: "forward.end")
            }
            .keyboardShortcut(.end, modifiers: [])
            .disabled(!windowManager.activeCanNavigate)

            Button {
                windowManager.randomImage()
            } label: {
                Label("Random Image", systemImage: "shuffle")
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(!windowManager.activeCanNavigate)
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
            .disabled(!windowManager.activeCanZoom)

            Toggle(
                isOn: Binding(
                    get: { windowManager.activeZoomToFill },
                    set: { windowManager.setZoomToFill($0) }
                )
            ) {
                Label("Zoom to Fill", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .keyboardShortcut("8")
            .disabled(!windowManager.activeCanZoom)

            Button {
                windowManager.actualSize()
            } label: {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .keyboardShortcut("0")
            .disabled(!windowManager.activeCanZoom)

            Button {
                windowManager.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+")
            .disabled(!windowManager.activeCanZoom)

            Button {
                windowManager.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-")
            .disabled(!windowManager.activeCanZoom)

            Button {
                windowManager.setZoomLevel()
            } label: {
                Label("Set Zoom Level…", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("l", modifiers: [])
            .disabled(!windowManager.activeCanZoom)

            Toggle(isOn: Binding(
                get: { windowManager.activeStickyZoom },
                set: { windowManager.setStickyZoom($0) }
            )) {
                Label("Sticky Zoom", systemImage: "pin")
            }
            .keyboardShortcut("z", modifiers: [])
            .disabled(!windowManager.hasOpenWindows)

            Divider()
        }

        CommandGroup(replacing: .help) {
        }
    }
}
