import SwiftUI

struct ImageViewerView: View {
    @ObservedObject var document: ImageDocument
    @ObservedObject var presentation: ViewerWindowPresentation
    @ObservedObject private var preferences = AppPreferences.shared
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
                    controller: viewportController,
                    dynamicRange: preferences.imageDynamicRange
                )
                .accessibilityLabel(document.displayName)
            } else if document.hasDecodeError {
                ContentUnavailableView {
                    Label(
                        "Unable to Open Image",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(
                        "The image format isn’t supported, or the file is damaged."
                    )
                }
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
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if
                preferences.hideTitleBar,
                presentation.isTitleBubbleVisible
            {
                HStack(spacing: 0) {
                    Text(presentation.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 8,
                                style: .continuous
                            )
                        )

                    Spacer(minLength: 0)
                }
                .opacity(0.5)
                .padding(.leading, 86)
                .padding(.trailing, 8)
                .padding(.top, 4)
                .allowsHitTesting(false)
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .opacity
                    )
                )
            }
        }
        .animation(
            presentation.isTitleBubbleVisible
                ? nil
                : .easeOut(duration: 0.2),
            value: presentation.isTitleBubbleVisible
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else {
                return false
            }
            return openDroppedFile(url)
        } isTargeted: {
            isDropTargeted = $0
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
