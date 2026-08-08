import SwiftUI

/// Today answers one question first: what needs doing now.
struct TodayView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Moves the app to the Companion tab after a successful start or resume.
    let onStartCompanion: () -> Void

    private var plan: TodayPlan { environment.plan }

    private var summary: TodayStatusSummary {
        TodayStatusSummary(
            state: environment.companion.state,
            capabilities: environment.capabilities
        )
    }

    private var mostImportantText: String {
        summary.hasFinishedSession ? summary.situation : plan.mostImportantThing
    }

    var body: some View {
        List {
            Section {
                TodayTaskOverviewCard(plan: plan)
                    .slowWalkReadableContent()
            }

            Section {
                Button(action: startOrContinueCompanion) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: mostImportantSystemImage)
                            .foregroundStyle(mostImportantTint)
                            .font(.title3)
                            .frame(width: 28)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(mostImportantText)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            if summary.isSessionUnderway {
                                Text(summary.stepLabel)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(mostImportantTint)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(summary.situation)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(summary.nextStep)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(summary.primaryActionTitle)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(mostImportantTint)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                .accessibilityLabel(
                    mostImportantAccessibilityLabel
                )
                .accessibilityHint("进入陪伴页面。")
                .slowWalkReadableContent()
            } header: {
                Text("现在最重要的事")
            } footer: {
                DemoDataFooter()
            }
        }
        .listStyle(.insetGrouped)
    }

    private var mostImportantSystemImage: String {
        if summary.hasFinishedSession {
            "checkmark.circle.fill"
        } else if summary.isSessionUnderway {
            "figure.walk"
        } else {
            "flag.fill"
        }
    }

    private var mostImportantTint: Color {
        if summary.hasFinishedSession {
            .green
        } else if summary.isSessionUnderway {
            .orange
        } else {
            .accentColor
        }
    }

    private var mostImportantAccessibilityLabel: String {
        var parts = ["现在最重要的事", mostImportantText]
        if summary.isSessionUnderway {
            parts.append(summary.stepLabel)
            parts.append(summary.situation)
        }
        parts.append(summary.nextStep)
        parts.append(summary.primaryActionTitle)
        return parts.joined(separator: "。")
    }

    private func startOrContinueCompanion() {
        if summary.isSessionUnderway {
            onStartCompanion()
            return
        }
        guard environment.companion.startCompanion() else { return }
        onStartCompanion()
    }
}

private struct TodayOverviewGoal: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let statusText: String
}

private struct TodayTaskOverviewCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let plan: TodayPlan

    private let ringRadius: CGFloat = 102
    private let ringWidth: CGFloat = 20

    private var completedMedicineCount: Int {
        plan.medicines.filter(\.isTakenToday).count
    }

    private var pendingMedicineCount: Int {
        plan.pendingMedicines.count
    }

    private var medicineProgress: Double {
        let total = plan.medicines.count
        return total == 0
            ? 0
            : Double(completedMedicineCount) / Double(total)
    }

    private var medicineTint: Color {
        if plan.medicines.isEmpty {
            .secondary
        } else if completedMedicineCount == plan.medicines.count {
            .green
        } else {
            .orange
        }
    }

    private var goals: [TodayOverviewGoal] {
        let medicineTotal = plan.medicines.count

        return [
            TodayOverviewGoal(
                id: "medicine",
                title: "用药",
                systemImage: "pills.fill",
                tint: medicineTint,
                statusText: medicineTotal == 0
                    ? "无"
                    : "\(completedMedicineCount)/\(medicineTotal)"
            ),
            TodayOverviewGoal(
                id: "outing",
                title: "出行",
                systemImage: "calendar",
                tint: plan.outing == nil ? .secondary : .blue,
                statusText: plan.outing == nil ? "无安排" : "已安排"
            ),
        ]
    }

    var body: some View {
        VStack(spacing: 16) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    taskHeading
                    pendingStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    taskHeading
                    Spacer()
                    pendingStatus
                }
            }

            TodaySemiRingSegment(
                progress: medicineProgress,
                tint: medicineTint,
                lineWidth: ringWidth,
                radius: ringRadius
            )
            .frame(
                width: ringRadius * 2 + ringWidth,
                height: ringRadius + ringWidth
            )
            .clipShape(Rectangle())
            .accessibilityHidden(true)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(goals) { goal in
                        accessibilityGoalRow(goal)
                    }
                }
            } else {
                HStack(alignment: .top) {
                    ForEach(goals) { goal in
                        compactGoalCell(goal)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var taskHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("今日安排")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("您好，\(plan.preferredName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var pendingStatus: some View {
        Text(pendingMedicineStatusText)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(
                pendingMedicineCount == 0 && !plan.medicines.isEmpty
                    ? .green
                    : .secondary
            )
    }

    private var pendingMedicineStatusText: String {
        if plan.medicines.isEmpty {
            "暂无用药安排"
        } else if pendingMedicineCount == 0 {
            "今日用药已完成"
        } else {
            "\(pendingMedicineCount)项用药待完成"
        }
    }

    private func compactGoalCell(_ goal: TodayOverviewGoal) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: goal.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(goal.tint)
                    .accessibilityHidden(true)
                Text(goal.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(goal.statusText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(goal.tint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(goal.title)，\(goal.statusText)")
    }

    private func accessibilityGoalRow(_ goal: TodayOverviewGoal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: goal.systemImage)
                .foregroundStyle(goal.tint)
                .accessibilityHidden(true)
            Text(goal.title)
            Spacer()
            Text(goal.statusText)
                .fontWeight(.semibold)
                .foregroundStyle(goal.tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(goal.title)，\(goal.statusText)")
    }
}

private struct TodaySemiRingSegment: View {
    let progress: Double
    let tint: Color
    let lineWidth: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            TodaySemiCircle()
                .stroke(
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    )
                )
                .foregroundStyle(tint.opacity(0.12))
            TodaySemiCircle()
                .trim(from: 0, to: progress)
                .stroke(
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    )
                )
                .foregroundStyle(tint)
        }
        .frame(width: radius * 2, height: radius)
    }
}

private struct TodaySemiCircle: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let radius = min(rect.width, rect.height * 2) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(360),
            clockwise: false
        )
        return path
    }
}

#Preview("Light") {
    NavigationStack {
        TodayView(onStartCompanion: {})
            .navigationTitle("今天")
    }
    .environment(AppEnvironment.preview())
}

#Preview("Dark AX5") {
    NavigationStack {
        TodayView(onStartCompanion: {})
            .navigationTitle("今天")
    }
    .environment(AppEnvironment.preview())
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
