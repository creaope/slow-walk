import SwiftUI

/// The app's three top-level destinations.
///
/// Today comes first so the app opens on "what needs doing now" rather than a
/// list of tools. Anti-fraud is deliberately not a top-level tab at this stage.
enum RootDestination: Hashable, CaseIterable, Identifiable {
    case today
    case companion
    case careRecords

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "今天"
        case .companion: "陪伴"
        case .careRecords: "守护记录"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .companion: "figure.walk"
        case .careRecords: "list.bullet.rectangle"
        }
    }
}

struct RootTabView: View {
    @State private var selection: RootDestination = .today
    @State private var isCareSettingsPresented = false

    var body: some View {
        // The iOS 18 `Tab` builder is deliberately not used: the app's
        // deployment target is iOS 17.0.
        TabView(selection: $selection) {
            ForEach(RootDestination.allCases) { destination in
                NavigationStack {
                    content(for: destination)
                        .navigationTitle(destination.title)
                }
                .tabItem {
                    Label(destination.title, systemImage: destination.systemImage)
                }
                .tag(destination)
            }
        }
        .sheet(isPresented: $isCareSettingsPresented) {
            NavigationStack {
                CareSettingsView()
                    .navigationTitle("关怀设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") {
                                isCareSettingsPresented = false
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func content(for destination: RootDestination) -> some View {
        switch destination {
        case .today:
            TodayView(onStartCompanion: { selection = .companion })
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isCareSettingsPresented = true
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .accessibilityLabel("个人与设置")
                        .accessibilityHint("打开个人信息与关怀设置。")
                    }
                }
        case .companion:
            CompanionView()
        case .careRecords:
            CareRecordsView()
        }
    }
}

#Preview {
    RootTabView()
        .environment(AppEnvironment.preview())
}
