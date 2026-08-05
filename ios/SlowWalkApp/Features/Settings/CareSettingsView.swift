import SwiftUI

/// Care settings for the current demo build.
struct CareSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var contactStatus: CapabilityStatus {
        environment.capabilities.status(of: .trustedContacts)
    }

    private var persistenceStatus: CapabilityStatus {
        environment.capabilities.status(of: .careRecordPersistence)
    }

    var body: some View {
        @Bindable var recognitionPreferences =
            environment.medicineRecognitionPreferences

        Form {
            Section {
                DemoDataBanner()
                    .slowWalkReadableContent()
            }

            Section {
                LabeledContent {
                    Text(environment.plan.preferredName)
                        .fontWeight(.semibold)
                } label: {
                    Label("称呼", systemImage: "person.text.rectangle")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "当前称呼，\(environment.plan.preferredName)，演示内容，只读"
                )
                .slowWalkReadableContent()
            } header: {
                Text("个人信息")
            } footer: {
                Text("当前称呼来自演示计划，本阶段暂不可修改。")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
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
                    Label("对比度与动态效果", systemImage: "accessibility")
                }
                .slowWalkReadableContent()
            } header: {
                Text("显示与辅助功能")
            } footer: {
                Text("这些选项由 iPhone 的辅助功能设置统一控制。")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(
                    isOn: $recognitionPreferences.onDeviceOnly
                ) {
                    Label(
                        "仅在设备上识别",
                        systemImage: "iphone.and.arrow.forward"
                    )
                }
                .slowWalkReadableContent()
            } header: {
                Text("药品识别与隐私")
            } footer: {
                Text(
                    MedicineRecognitionPrivacyCopy.description(
                        onDeviceOnly:
                            recognitionPreferences.onDeviceOnly,
                        onlineRecognitionConfigured:
                            environment
                                .medicineRecognitionServerConfiguration
                                .baseURL != nil
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                capabilityRow(
                    contactStatus,
                    title: "信任联系人",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )

                capabilityRow(
                    persistenceStatus,
                    title: "守护记录",
                    systemImage: "internaldrive"
                )
            } header: {
                Text("关怀与数据")
            } footer: {
                if !capabilityDetails.isEmpty {
                    Text(capabilityDetails)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
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
            } header: {
                Text("说明")
            }
        }
    }

    private var capabilityDetails: String {
        [contactStatus.detail, persistenceStatus.detail]
            .compactMap(\.self)
            .joined(separator: " ")
    }

    private func capabilityRow(
        _ status: CapabilityStatus,
        title: String,
        systemImage: String
    ) -> some View {
        LabeledContent {
            Text(status.shortLabel)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.summaryLine)
        .slowWalkReadableContent()
    }
}

enum MedicineRecognitionPrivacyCopy {
    static func description(
        onDeviceOnly: Bool,
        onlineRecognitionConfigured: Bool
    ) -> String {
        if onDeviceOnly {
            return "药品包装图片只在这台设备上处理。"
        }
        if onlineRecognitionConfigured {
            return "药品包装图片会优先发送到已配置的识别服务；"
                + "服务不可用时改在设备上处理。"
        }
        return "当前未配置在线识别服务，药品包装图片只在设备上处理。"
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
