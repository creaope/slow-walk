import SwiftUI

/// Today answers one question first: what needs doing now.
///
/// It is deliberately not a grid of four feature buttons. The most important
/// thing comes first, then today's medicines and outing, then the single
/// primary action.
struct TodayView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Moves the app to the Companion tab, either after Today has started a new
    /// session or to return to one already underway.
    let onStartCompanion: () -> Void

    private var plan: TodayPlan { environment.plan }

    private var summary: TodayStatusSummary {
        TodayStatusSummary(
            state: environment.companion.state,
            capabilities: environment.capabilities
        )
    }

    /// The headline. Once a session has finished, the plan's opening line would
    /// contradict the status card below it, so the finished state wins.
    private var mostImportantText: String {
        summary.hasFinishedSession ? summary.situation : plan.mostImportantThing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DemoDataBanner()
                greeting
                mostImportantCard
                primaryAction
                if summary.isSessionUnderway || summary.hasFinishedSession {
                    currentStatusCard
                }
                medicinesSection
                if let outing = plan.outing {
                    outingSection(outing)
                }
                NotADiagnosisNotice()
            }
            .padding()
        }
    }

    // MARK: - Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The name is configurable and never invented; no family role is
            // assumed anywhere in the greeting.
            Text("您好，\(plan.preferredName)")
                .font(.title2)
                .fontWeight(.semibold)
            Text("今天我陪您一起完成。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var mostImportantCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("现在最重要的事")
                .font(.headline)
            Text(mostImportantText)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("现在最重要的事。\(mostImportantText)")
    }

    private var primaryAction: some View {
        Button(action: startOrContinueCompanion) {
            Text(summary.primaryActionTitle)
                .font(.title3)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(summary.primaryActionTitle)
        .accessibilityHint("进入陪伴流程，逐步完成今天的安排。")
    }

    /// Backs the primary action, which reads either "开始陪伴" or "继续陪伴".
    ///
    /// A session underway is only navigated to, since starting is refused from
    /// every active step. Otherwise the tab changes only if one really started.
    private func startOrContinueCompanion() {
        if summary.isSessionUnderway {
            onStartCompanion()
            return
        }
        guard environment.companion.startCompanion() else { return }
        onStartCompanion()
    }

    private var currentStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前陪伴状态")
                .font(.headline)
            Text(summary.stepLabel)
                .font(.title3)
                .fontWeight(.medium)
            Text(summary.situation)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.nextStep)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.accessibilityLabel)
    }

    private var medicinesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日用药")
                .font(.headline)

            if plan.medicines.isEmpty {
                Text("今天没有需要记录的用药。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plan.medicines) { medicine in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        // Status is carried by wording and a shape, never by
                        // colour alone.
                        Image(systemName: medicine.isTakenToday
                            ? "checkmark.circle"
                            : "circle")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(medicine.displayName)
                                .font(.body)
                            Text(medicine.timeOfDayDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(medicine.isTakenToday ? "已完成" : "待完成")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(medicine.displayName)，\(medicine.timeOfDayDescription)，"
                            + (medicine.isTakenToday ? "已完成" : "待完成")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outingSection(_ outing: TodayOutingItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今日复诊或外出")
                .font(.headline)
            Text(outing.title)
                .font(.body)
            Text("\(outing.timeDescription) · \(outing.placeDescription)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "今日复诊或外出：\(outing.title)，\(outing.timeDescription)，\(outing.placeDescription)"
        )
    }
}

#Preview {
    NavigationStack {
        TodayView(onStartCompanion: {})
            .navigationTitle("今天")
    }
    .environment(AppEnvironment.preview())
}
