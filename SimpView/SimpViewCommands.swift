import SwiftUI

struct SimpViewCommands: Commands {
    @ObservedObject private var windowManager = WindowManager.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
        }

        CommandGroup(replacing: .newItem) {
            Button {
                windowManager.openImage()
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut("o")

            Button {
                windowManager.newWindow()
            } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }
            .keyboardShortcut("n")

            Divider()

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
            Button {
                windowManager.showInFinder()
            } label: {
                Label("Show in Finder", systemImage: "finder")
            }
            .disabled(windowManager.activeImageURL == nil)
        }

        CommandGroup(replacing: .saveItem) {
        }
    }
}
