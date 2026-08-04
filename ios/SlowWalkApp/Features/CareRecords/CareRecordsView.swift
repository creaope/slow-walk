import SwiftUI

/// The factual timeline of one companion session.
struct CareRecordsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var events: [CareRecordEvent] {
        environment.careRecords.events
    }

    private var persistenceStatus: CapabilityStatus {
        environment.capabilities.status(of: .careRecordPersistence)
    }

    var body: some View {
        List {
            Section {
                DemoDataBanner()
                    .slowWalkReadableContent()
            }

            if events.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有记录",
                        systemImage: "clock.badge.questionmark",
                        description: Text("开始一次陪伴之后，这里会按时间记录每一步。")
                    )
                    .slowWalkReadableContent()
                }
            } else {
                Section("陪伴过程") {
                    ForEach(events) { event in
                        row(for: event)
                            .slowWalkReadableContent()
                    }
                }
            }

            Section("记录说明") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("守护记录保存")
                            .font(.headline)
                        Text(persistenceStatus.shortLabel)
                            .foregroundStyle(.secondary)
                        if let detail = persistenceStatus.detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(persistenceStatus.summaryLine)
                .slowWalkReadableContent()
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for event: CareRecordEvent) -> some View {
        let time = event.occurredAt.formatted(Self.timeStyle)

        return Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Self.description(for: event.kind))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: Self.systemImage(for: event.kind))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(time)，\(Self.description(for: event.kind))")
    }

    private static func systemImage(for kind: CareRecordEventKind) -> String {
        switch kind {
        case .dayPlanItemStarted:
            "calendar.badge.clock"
        case .medicineReadStarted:
            "camera.viewfinder"
        case .medicineReadDidNotSucceed:
            "arrow.clockwise.circle"
        case .medicineReadFoundCandidates:
            "list.bullet.rectangle"
        case .medicineConfirmed:
            "checkmark.circle"
        case .medicineAssessmentDidNotSucceed:
            "exclamationmark.arrow.triangle.2.circlepath"
        case .careActionShown:
            "rectangle.and.text.magnifyingglass"
        case .companionFinished:
            "flag.checkered"
        }
    }

    /// Neutral descriptions of recorded events, never medical conclusions.
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
                "已确认药名：\(medicineName)"
            case .chosenFromFrequentList:
                "已确认药名：\(medicineName)（从常用药名选择）"
            }
        case .medicineAssessmentDidNotSucceed:
            "用药评估未能完成，未显示用药提示"
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

    private static let timeStyle = Date.FormatStyle(
        date: .omitted,
        time: .shortened
    )
}

#Preview("Empty") {
    NavigationStack {
        CareRecordsView()
            .navigationTitle("守护记录")
    }
    .environment(AppEnvironment.preview())
}

#Preview("Dark AX5") {
    NavigationStack {
        CareRecordsView()
            .navigationTitle("守护记录")
    }
    .environment(AppEnvironment.preview())
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
