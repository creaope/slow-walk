import SwiftUI

/// The timeline of what happened while accompanying someone.
///
/// Records describe the process, not a medical outcome. A read that did not
/// succeed is recorded as an event with a recovery path, never as a conclusion
/// about a medicine.
struct CareRecordsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var events: [CareRecordEvent] {
        environment.careRecords.events
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DemoDataBanner()

                if events.isEmpty {
                    emptyState
                } else {
                    ForEach(events) { event in
                        row(for: event)
                    }
                }

                // From the app-level capability source, not a fixed string: if
                // records ever become persistent, this line changes with the
                // table instead of being corrected here.
                Text(
                    environment.capabilities
                        .detail(of: .careRecordPersistence)
                        ?? "记录只保存在内存中，重新启动后会清空。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有记录")
                .font(.headline)
            Text("开始一次陪伴之后，这里会按时间记录每一步。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row(for event: CareRecordEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.timeFormatter.string(from: event.occurredAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.description(for: event.kind))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(Self.timeFormatter.string(from: event.occurredAt))，"
                + Self.description(for: event.kind)
        )
    }

    // MARK: - Wording

    /// Neutral, factual descriptions. Nothing here blames the person.
    static func description(for kind: CareRecordEventKind) -> String {
        switch kind {
        case let .dayPlanItemStarted(title):
            "开始今天的安排：\(title)"
        case let .medicineReadStarted(attemptNumber):
            attemptNumber == 1
                ? "开始读取药盒"
                : "第 \(attemptNumber) 次读取药盒"
        case let .medicineReadDidNotSucceed(setback):
            switch setback {
            case .textNotLegible:
                "这次没有看清药盒上的字，已提供重试方式"
            case .noMedicineNameFound:
                "这次没有找到药名，已提供重试方式"
            }
        case let .medicineReadFoundCandidates(candidateCount):
            "这次读到 \(candidateCount) 个相近的药名，等待确认"
        case let .medicineConfirmed(medicineName, origin):
            switch origin {
            case .readFromPhoto:
                "已确认药名：\(medicineName)（模拟识别后确认）"
            case .chosenFromFrequentList:
                "已确认药名：\(medicineName)（从常用药名选择）"
            }
        case let .medicineAssessmentDidNotSucceed(reason):
            switch reason {
            case .capabilityNotAvailableYet:
                "尚未完成用药风险评估：设备内评估将在下一阶段接入"
            }
        case let .careActionShown(medicineName):
            "已显示\(medicineName)的用药提示"
        case let .companionFinished(completion):
            switch completion {
            case .arrivedSafely:
                "陪伴结束：已安全到达"
            case .completedMedicineCheck:
                "陪伴结束：已完成用药检查"
            case .endedEarly:
                "陪伴结束：提前结束"
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

#Preview {
    NavigationStack {
        CareRecordsView()
            .navigationTitle("守护记录")
    }
    .environment(AppEnvironment.preview())
}
