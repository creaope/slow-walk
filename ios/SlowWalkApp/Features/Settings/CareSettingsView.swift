import SwiftUI

/// Skeleton for care settings.
///
/// Nothing here is persisted yet, and that is stated on screen rather than
/// implied. Real persistence waits for protected storage: `ios/README.md`
/// records that the current JSON repository has no Apple Data Protection, so
/// real health data must not be written.
struct CareSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Session-only, so nothing suggests a saved preference.
    @State private var preferredName: String = ""
    @State private var prefersLargerText = false
    @State private var prefersSpokenReminders = false

    var body: some View {
        Form {
            Section {
                DemoDataBanner()
            }

            Section("称呼") {
                TextField(
                    "希望我们怎么称呼您",
                    text: $preferredName,
                    prompt: Text(environment.plan.preferredName)
                )
                .accessibilityLabel("希望我们怎么称呼您")
                Text("称呼由您决定，我们不会代替您设定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("提示方式") {
                // Neither switch is connected yet. Leaving them tappable would
                // present a setting that silently does nothing, so they are
                // disabled and the reason is stated on screen.
                Toggle("使用更大的字号", isOn: $prefersLargerText)
                    .disabled(true)
                Toggle("重要提示同时朗读", isOn: $prefersSpokenReminders)
                    .disabled(true)
                Text("这两项尚未接入。字号目前跟随系统的“显示与文字大小”设置，朗读功能将在后续阶段接入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("紧急联系人") {
                CapabilityStatusRow(
                    status: environment.capabilities.status(of: .trustedContacts)
                )
                Text("可以联系谁由您自己决定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // The honest capability list, and the entry point for checking it.
            // Read from `environment.capabilities` — the same value the
            // companion session runs against — so this section and the in-flow
            // wording cannot disagree: there is one table, and changing a
            // capability's real state changes both at once.
            Section("当前能力状态") {
                CapabilityStatusList(catalog: environment.capabilities)
                Text("此列表说明各项能力当前的实现方式，不说明用药是否安全。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("关于") {
                NotADiagnosisNotice()
                Text("本阶段的设置只在本次运行内有效，尚未保存到设备。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        CareSettingsView()
            .navigationTitle("关怀设置")
    }
    .environment(AppEnvironment.preview())
}
