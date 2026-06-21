import SwiftUI

struct ImageViewerView: View {
    @ObservedObject var document: ImageDocument
    let openDroppedFile: (URL) -> Bool
    let zoomChanged: (Double?) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if document.isShowingLoadingIndicator {
                    ContentUnavailableView {
                        ProgressView()
                            .controlSize(.large)
                    } description: {
                        Text("Loading Image…")
                    }
                } else if let image = document.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .onAppear {
                reportZoom(availableSize: geometry.size)
            }
            .onChange(of: geometry.size) {
                reportZoom(availableSize: $1)
            }
            .onChange(of: document.image?.size) {
                reportZoom(availableSize: geometry.size)
            }
        }
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

    private func reportZoom(availableSize: CGSize) {
        guard
            let imageSize = document.image?.size,
            imageSize.width > 0,
            imageSize.height > 0
        else {
            zoomChanged(nil)
            return
        }

        let scale = min(
            availableSize.width / imageSize.width,
            availableSize.height / imageSize.height
        )
        zoomChanged(scale * 100)
    }
}
