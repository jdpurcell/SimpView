import SwiftUI

struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Zoom step") {
                    HStack(spacing: 8) {
                        Text("\(preferences.zoomStepPercent)%")
                            .monospacedDigit()
                            .frame(minWidth: 48, alignment: .trailing)

                        Stepper(
                            "Zoom step",
                            value: zoomStep,
                            in: 1...100
                        )
                        .labelsHidden()
                    }
                }

                LabeledContent("Sort by") {
                    Picker("Sort by", selection: imageSortField) {
                        Text("File Name").tag(ImageSortField.name)
                        Text("Date Modified")
                            .tag(ImageSortField.modificationDate)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                LabeledContent("Sort order") {
                    Picker("Sort order", selection: imageSortDirection) {
                        Text("Ascending")
                            .tag(SortDirection.ascending)
                        Text("Descending")
                            .tag(SortDirection.descending)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            } header: {
                Text("Images")
            }

            Section {
                Toggle(
                    "Preload adjacent images",
                    isOn: preloadAdjacentImages
                )

                LabeledContent("Navigation speed") {
                    HStack(spacing: 8) {
                        Text(
                            "\(preferences.navigationIntervalMilliseconds) ms"
                        )
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)

                        Stepper(
                            "Navigation speed",
                            value: navigationInterval,
                            in: 10...500,
                            step: 10
                        )
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Navigation")
            }

            Section {
                LabeledContent("Remember session when quitting") {
                    Picker(
                        "Remember session when quitting",
                        selection: sessionQuitBehavior
                    ) {
                        Text("Follow System Setting")
                            .tag(SessionQuitBehavior.followSystemSetting)
                        Text("Ask When Quitting")
                            .tag(SessionQuitBehavior.askWhenQuitting)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                Toggle(
                    "Quit when last window is closed",
                    isOn: quitOnLastWindowClosed
                )

                Toggle(
                    "Hide window title bar",
                    isOn: hideTitleBar
                )
            } header: {
                Text("Application")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var zoomStep: Binding<Int> {
        Binding(
            get: { preferences.zoomStepPercent },
            set: { preferences.setZoomStepPercent($0) }
        )
    }

    private var imageSortField: Binding<ImageSortField> {
        Binding(
            get: { preferences.imageSortField },
            set: { preferences.setImageSortField($0) }
        )
    }

    private var imageSortDirection: Binding<SortDirection> {
        Binding(
            get: { preferences.imageSortDirection },
            set: { preferences.setImageSortDirection($0) }
        )
    }

    private var navigationInterval: Binding<Int> {
        Binding(
            get: { preferences.navigationIntervalMilliseconds },
            set: {
                preferences.setNavigationIntervalMilliseconds($0)
            }
        )
    }

    private var preloadAdjacentImages: Binding<Bool> {
        Binding(
            get: { preferences.preloadAdjacentImages },
            set: { preferences.setPreloadAdjacentImages($0) }
        )
    }

    private var sessionQuitBehavior: Binding<SessionQuitBehavior> {
        Binding(
            get: { preferences.sessionQuitBehavior },
            set: { preferences.setSessionQuitBehavior($0) }
        )
    }

    private var quitOnLastWindowClosed: Binding<Bool> {
        Binding(
            get: { preferences.quitOnLastWindowClosed },
            set: { preferences.setQuitOnLastWindowClosed($0) }
        )
    }

    private var hideTitleBar: Binding<Bool> {
        Binding(
            get: { preferences.hideTitleBar },
            set: { preferences.setHideTitleBar($0) }
        )
    }
}
