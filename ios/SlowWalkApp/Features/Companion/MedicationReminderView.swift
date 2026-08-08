import SwiftUI

/// A presentation-only view of the medication items already present in today's
/// plan. Notification scheduling and medication persistence are intentionally
/// outside this view until those services have real app-level implementations.
struct MedicationReminderView: View {
    let medicines: [TodayMedicineItem]
    let reminderStatus: CapabilityStatus

    private var pendingMedicines: [TodayMedicineItem] {
        medicines.filter { !$0.isTakenToday }
    }

    private var completedCount: Int {
        medicines.count - pendingMedicines.count
    }

    var body: some View {
        List {
            if medicines.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有用药提醒",
                        systemImage: "bell.slash",
                        description: Text("用药提醒会在这里显示。")
                    )
                    .slowWalkReadableContent()
                }
            } else {
                Section("今天") {
                    reminderSummary
                        .slowWalkReadableContent()

                    LabeledContent("待完成", value: "\(pendingMedicines.count) 项")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("今天待完成 \(pendingMedicines.count) 项")
                        .slowWalkReadableContent()

                    LabeledContent("已完成", value: "\(completedCount) 项")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("今天已完成 \(completedCount) 项")
                        .slowWalkReadableContent()
                }

                Section("今日用药") {
                    ForEach(medicines) { medicine in
                        reminderRow(medicine)
                            .slowWalkReadableContent()
                    }
                }
            }

            Section {
                LabeledContent {
                    Text("演示提醒")
                        .foregroundStyle(.secondary)
                } label: {
                    Label(
                        reminderStatus.displayName,
                        systemImage: "bell.slash"
                    )
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(reminderAccessibilityLabel)
                .slowWalkReadableContent()
            } header: {
                Text("提醒状态")
            } footer: {
                Text("当前为演示安排，不会发送系统通知。")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                DemoDataFooter()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("用药提醒")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var reminderSummary: some View {
        Label {
            Text(summaryText)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(
                systemName: pendingMedicines.isEmpty
                    ? "checkmark.circle.fill"
                    : "bell.badge.fill"
            )
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryText: String {
        if pendingMedicines.isEmpty {
            "今天的用药安排已全部完成"
        } else {
            "今天还有 \(pendingMedicines.count) 项待完成"
        }
    }

    /// Honest VoiceOver reading for the reminder-status row: it names the
    /// capability, states it is a demo reminder, and is explicit that no system
    /// notification is sent.
    private var reminderAccessibilityLabel: String {
        "\(reminderStatus.displayName)：演示提醒。当前为演示安排，不会发送系统通知。"
    }

    private func reminderRow(_ medicine: TodayMedicineItem) -> some View {
        let status = medicine.isTakenToday ? "已完成" : "待完成"

        return LabeledContent {
            Label(
                status,
                systemImage: medicine.isTakenToday
                    ? "checkmark.circle.fill"
                    : "circle"
            )
            .foregroundStyle(.secondary)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(medicine.displayName)
                        .fontWeight(.semibold)
                    Text(medicine.timeOfDayDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "pills")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(medicine.displayName)，\(medicine.timeOfDayDescription)，\(status)"
        )
    }
}

#Preview("Today") {
    NavigationStack {
        MedicationReminderView(
            medicines: TodayPlan.demo.medicines,
            reminderStatus: CapabilityCatalog.phase0.status(
                of: .medicationReminder
            )
        )
    }
}

#Preview("Empty") {
    NavigationStack {
        MedicationReminderView(
            medicines: [],
            reminderStatus: CapabilityCatalog.phase0.status(
                of: .medicationReminder
            )
        )
    }
}

#Preview("Dark AX5") {
    NavigationStack {
        MedicationReminderView(
            medicines: TodayPlan.demo.medicines,
            reminderStatus: CapabilityCatalog.phase0.status(
                of: .medicationReminder
            )
        )
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
