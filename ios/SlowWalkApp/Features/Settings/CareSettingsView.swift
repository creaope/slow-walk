import SwiftUI

/// Read-only care settings for the current demo build.
struct CareSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var contactStatus: CapabilityStatus {
        environment.capabilities.status(of: .trustedContacts)
    }

    var body: some View {
        Form {
            Section {
                DemoDataBanner()
                    .slowWalkReadableContent()
            }

            Section("称呼") {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(environment.plan.preferredName)
                            .fontWeight(.semibold)
                        Text("演示内容，只读")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("当前称呼", systemImage: "person.text.rectangle")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "当前称呼，\(environment.plan.preferredName)，演示内容，只读"
                )
                .slowWalkReadableContent()

                Text("当前称呼来自演示计划，本阶段暂不可修改。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slowWalkReadableContent()
            }

            Section("显示与辅助功能") {
                LabeledContent {
                    Text("跟随系统")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("文字大小", systemImage: "textformat.size")
                }
                .slowWalkReadableContent()

                LabeledContent {
                    Text("跟随系统")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("粗体与对比度", systemImage: "accessibility")
                }
                .slowWalkReadableContent()
            }

            Section("信任联系人") {
                LabeledContent {
                    Text(contactStatus.shortLabel)
                        .foregroundStyle(.secondary)
                } label: {
                    Label(
                        "联系人",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(contactStatus.summaryLine)
                .slowWalkReadableContent()

                if let detail = contactStatus.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .slowWalkReadableContent()
                }
            }

            Section("说明") {
                NavigationLink {
                    SafetyInformationView()
                } label: {
                    Label(
                        "安全与使用说明",
                        systemImage: "shield.lefthalf.filled"
                    )
                }
                .accessibilityHint("查看演示数据、功能边界和数据保存说明。")
                .slowWalkReadableContent()
            }
        }
    }
}

#Preview("Light") {
    NavigationStack {
        CareSettingsView()
            .navigationTitle("关怀设置")
    }
    .environment(AppEnvironment.preview())
}

#Preview("Dark AX5") {
    NavigationStack {
        CareSettingsView()
            .navigationTitle("关怀设置")
    }
    .environment(AppEnvironment.preview())
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
