import SwiftUI

/// Factual product boundaries presented without adding medical advice.
struct SafetyInformationView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            Section {
                DemoDataBanner()
                    .slowWalkReadableContent()
            }

            Section("使用边界") {
                NotADiagnosisNotice()
                    .slowWalkReadableContent()
            }

            Section("当前能力状态") {
                ForEach(environment.capabilities.allStatuses) { status in
                    capabilityRow(status)
                        .slowWalkReadableContent()
                }

                Text("能力状态只说明当前实现方式，不说明用药是否安全。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slowWalkReadableContent()
            }

            Section("显示与辅助功能") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("跟随系统设置")
                            .font(.headline)
                        Text("文字大小、粗体文本、对比度和动态效果会跟随设备的辅助功能设置。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "accessibility")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .slowWalkReadableContent()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("安全与使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capabilityRow(_ status: CapabilityStatus) -> some View {
        LabeledContent {
            Text(status.shortLabel)
                .foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.displayName)
                if let detail = status.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.summaryLine)
    }
}

#Preview("Light") {
    NavigationStack {
        SafetyInformationView()
    }
    .environment(AppEnvironment.preview())
}

#Preview("Dark AX5") {
    NavigationStack {
        SafetyInformationView()
    }
    .environment(AppEnvironment.preview())
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
