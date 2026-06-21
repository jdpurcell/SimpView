import SwiftUI

struct ImageViewerView: View {
    @ObservedObject var document: ImageDocument
    let viewportController: ImageViewportController
    let openDroppedFile: (URL) -> Bool

    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if document.isShowingLoadingIndicator {
                ContentUnavailableView {
                    ProgressView()
                        .controlSize(.large)
                } description: {
                    Text("Loading Image…")
                }
            } else if let image = document.image {
                ImageViewport(
                    image: image,
                    controller: viewportController
                )
                .accessibilityLabel(document.displayName)
            } else {
                ContentUnavailableView {
                    Label("No Image", systemImage: "photo")
                } description: {
                    Text("Open an image to view it.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else {
                return false
            }
            return openDroppedFile(url)
        } isTargeted: {
            isDropTargeted = $0
        }
    }
}
