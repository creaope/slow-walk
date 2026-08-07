import Foundation

/// How a capability is actually implemented right now.
///
/// This describes *implementation availability only*. It is deliberately not a
/// medical or risk vocabulary: nothing here participates in assessing a
/// medicine, and no value of this type may ever be mapped onto a
/// `SlowWalkDomain.RiskLevel`. A capability being `.deviceLocal` says the code
/// path runs on this device; it says nothing about whether a result is safe.
///
/// The order of the cases is the order of honesty, not of preference: a
/// capability must be described by what it really does, so a simulated
/// capability is never presented as an online one.
enum CapabilityAvailability: Equatable, Hashable, CaseIterable {
    /// Driven by scripted demo data. No real sensor, no real service.
    case simulated
    /// Runs on this device against real local code. No network involved.
    case deviceLocal
    /// Requires a network service to work at all.
    case online
    /// Not implemented yet. Nothing behind it.
    case unavailable

    /// The short badge shown next to a capability's name.
    ///
    /// These four strings are the only place the availability vocabulary is
    /// written down, so two screens can never disagree about what "simulated"
    /// is called. They are deliberately distinct from one another: no two
    /// share a prefix, so "模拟" can never be read as "设备内".
    var shortLabel: String {
        switch self {
        case .simulated: "模拟识别"
        case .deviceLocal: "设备内"
        case .online: "需要联网"
        case .unavailable: "尚未接入"
        }
    }

    /// Whether the capability does anything at all today.
    ///
    /// `.unavailable` is the only value that means "nothing happens". A
    /// simulated capability does run — it just runs on demo data — so callers
    /// that need to know "is this real" must ask `isRealImplementation`
    /// instead of treating everything non-`unavailable` as working.
    var isImplemented: Bool {
        self != .unavailable
    }

    /// Whether the capability works on real input rather than demo data.
    ///
    /// This is the question a screen must ask before it claims something about
    /// the world — "正在读取照片", "正在记录路线". `.simulated` answers `false`.
    var isRealImplementation: Bool {
        switch self {
        case .deviceLocal, .online: true
        case .simulated, .unavailable: false
        }
    }
}

/// A capability of the app whose real availability must be stated on screen.
///
/// Every case here is something a person could otherwise be misled about. The
/// list is closed and `CaseIterable` so a capability cannot be described in one
/// screen and forgotten in another.
enum AppCapability: Equatable, Hashable, CaseIterable, Identifiable {
    case medicineRecognition
    case medicineRiskAssessment
    case medicationReminder
    case visionOCR
    case coreLocation
    case arrivalReminder
    case careRecordPersistence
    case trustedContacts
    /// Whether the SlowWalk server is required for the app to run.
    case serverDependency

    var id: Self { self }

    var displayName: String {
        switch self {
        case .medicineRecognition: "药品识别"
        case .medicineRiskAssessment: "药品风险评估"
        case .medicationReminder: "用药提醒通知"
        case .visionOCR: "照片文字识别（Vision）"
        case .coreLocation: "真实定位（CoreLocation）"
        case .arrivalReminder: "到站提醒"
        case .careRecordPersistence: "守护记录保存"
        case .trustedContacts: "信任联系人"
        case .serverDependency: "SlowWalk 服务端"
        }
    }
}

/// The single source of truth for what this build can actually do.
///
/// Screens read availability from here instead of hardcoding a claim, so a
/// capability's real state is written once. When a capability is genuinely
/// implemented, its value changes here and every screen follows.
///
/// Kept as a value type with an injectable table so a test can describe a
/// hypothetical build without mutating the shipping one.
struct CapabilityCatalog: Equatable, Hashable {
    private let availabilityByCapability: [AppCapability: CapabilityAvailability]

    /// A capability's explanatory line, when a badge alone would be ambiguous.
    ///
    /// Required wherever the badge alone would mislead. `serverDependency` is
    /// the clearest case: the badge says "尚未接入", but the honest fact is that
    /// the server exists and simply is not a dependency of this app.
    private let detailByCapability: [AppCapability: String]

    init(
        availability: [AppCapability: CapabilityAvailability],
        detail: [AppCapability: String] = [:]
    ) {
        availabilityByCapability = availability
        detailByCapability = detail
    }

    /// A capability with no entry is reported `.unavailable`.
    ///
    /// Defaulting to "nothing is behind this" is the only safe direction: a
    /// capability added to `AppCapability` and forgotten here is understated,
    /// never overstated.
    func availability(of capability: AppCapability) -> CapabilityAvailability {
        availabilityByCapability[capability] ?? .unavailable
    }

    func detail(of capability: AppCapability) -> String? {
        detailByCapability[capability]
    }

    /// One capability packaged for display.
    ///
    /// The single way a screen turns a capability into something renderable.
    /// Views call this instead of assembling a `CapabilityStatus` from separate
    /// `availability(of:)` and `detail(of:)` lookups, so a screen cannot pair
    /// one capability's badge with another's explanation, and a test can assert
    /// on exactly what a view will show.
    func status(of capability: AppCapability) -> CapabilityStatus {
        CapabilityStatus(
            capability: capability,
            availability: availability(of: capability),
            detail: detail(of: capability)
        )
    }

    /// Every capability with its availability, in a stable order.
    var allStatuses: [CapabilityStatus] {
        AppCapability.allCases.map(status(of:))
    }
}

/// One capability paired with what it can really do, ready to display.
struct CapabilityStatus: Equatable, Hashable, Identifiable {
    let capability: AppCapability
    let availability: CapabilityAvailability
    let detail: String?

    var id: AppCapability { capability }

    var displayName: String { capability.displayName }
    var shortLabel: String { availability.shortLabel }

    /// The full line for a status list: name, badge, and the reason when there
    /// is one.
    var summaryLine: String {
        if let detail {
            "\(displayName)：\(shortLabel)。\(detail)"
        } else {
            "\(displayName)：\(shortLabel)"
        }
    }
}

extension CapabilityCatalog {
    /// What this build can really do, as of Phase 0.
    ///
    /// Every value here is checked against the source that implements it:
    ///
    /// - `medicineRecognition` — `MockMedicineScanSimulator` hands out a fixed
    ///   script. No camera, no image.
    /// - `medicineRiskAssessment` — `.unavailable`, not `.deviceLocal`.
    ///   `MedicinePipeline` exists in `SlowWalkCore`, but no adapter in this
    ///   target calls it, so the app cannot assess anything today. It becomes
    ///   `.deviceLocal` when `LocalMedicineAssessmentRequester` lands.
    /// - `medicationReminder` — the UI can display today's plan, but there is no
    ///   medication schedule store or notification scheduler in this target.
    /// - `visionOCR` — no Vision adapter exists in this target.
    /// - `coreLocation` — no CoreLocation adapter exists in this target; the
    ///   travelling step is advanced by a button, not by movement.
    /// - `arrivalReminder` — nothing observes arrival; "即将到站" is a manual
    ///   demo step.
    /// - `careRecordPersistence` — `InMemoryCareRecordStore` only. Protected
    ///   storage is required first (`ios/README.md`).
    /// - `trustedContacts` — the recovery button is present but disabled.
    /// - `serverDependency` — `.unavailable` describes this *app's* wiring, not
    ///   the server's existence. The SlowWalk server is a real part of the
    ///   project; nothing in this target opens a connection to it, so it is not
    ///   a default runtime dependency. The detail line has to say both, because
    ///   the badge alone ("尚未接入") would read as "there is no server". It is
    ///   deliberately not `.online`: marking it online would state that the app
    ///   needs a network service to work, which is the opposite of true.
    static let phase0 = CapabilityCatalog(
        availability: [
            .medicineRecognition: .simulated,
            .medicineRiskAssessment: .unavailable,
            .medicationReminder: .unavailable,
            .visionOCR: .unavailable,
            .coreLocation: .unavailable,
            .arrivalReminder: .unavailable,
            .careRecordPersistence: .unavailable,
            .trustedContacts: .unavailable,
            .serverDependency: .unavailable,
        ],
        detail: [
            .medicineRecognition: "候选药名来自固定演示脚本，不读取相机图片。",
            .medicineRiskAssessment: "设备内评估将在下一阶段接入，本阶段不会给出风险等级。",
            .medicationReminder: "当前只展示今日用药安排，不会发送系统通知。",
            .visionOCR: "尚未接入照片文字识别。",
            .coreLocation: "本阶段使用演示位置，出行步骤由手动操作推进。",
            .arrivalReminder: "本阶段不会自动提醒到站。",
            .careRecordPersistence: "记录只保存在内存中，重新启动后会清空。",
            .trustedContacts: "本阶段尚未接入联系功能。",
            .serverDependency: """
                服务端存在，但不是本 App 的默认运行依赖。\
                App 不连接服务端也能走完本阶段流程。
                """,
        ]
    )
}
