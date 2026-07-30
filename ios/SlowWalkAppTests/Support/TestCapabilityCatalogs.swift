import Testing
@testable import SlowWalkApp

/// Capability tables describing hypothetical builds, for tests only.
///
/// `CapabilityCatalog` is injectable so a test can describe a build that does
/// not exist yet — one where the device-local assessment has landed, for
/// instance — and check that behaviour and wording both follow it. These tables
/// are deliberately different from `.phase0` in ways a test can detect: any
/// screen still reading the shipping table shows the wrong badge or the wrong
/// sentence, which is what the consistency tests look for.
///
/// None of these describe the shipping build. `.phase0` remains the only
/// production table, assembled once in `AppEnvironment`.
enum TestCapabilityCatalogs {

    /// A build where the device-local medicine assessment has been wired up.
    ///
    /// This is the next stage's table. Its detail line says the assessment runs
    /// on the device, so any screen that still says "尚未接入" for assessment is
    /// reading a different catalog than the session is.
    ///
    /// Note what this table does *not* buy: the gate still holds, because
    /// `MedicineAssessmentProgress` has no success case for an adapter to
    /// produce. A capability table cannot talk the flow into presenting a result
    /// that does not exist — asserted in `assessmentAvailableStillCannotDepart`.
    static let assessmentAvailable = CapabilityCatalog(
        availability: [
            .medicineRecognition: .simulated,
            .medicineRiskAssessment: .deviceLocal,
            .visionOCR: .unavailable,
            .coreLocation: .unavailable,
            .arrivalReminder: .unavailable,
            .careRecordPersistence: .unavailable,
            .trustedContacts: .unavailable,
            .serverDependency: .unavailable,
        ],
        detail: [
            .medicineRecognition: "候选药名来自固定演示脚本，不读取相机图片。",
            .medicineRiskAssessment: "设备内评估已接入，评估在本机完成，不上传照片。",
            .careRecordPersistence: "记录只保存在内存中，重新启动后会清空。",
            .trustedContacts: "本阶段尚未接入联系功能。",
            .serverDependency: "服务端存在，但不是本 App 的默认运行依赖。",
        ]
    )

    /// A table whose every explanation is recognisably not the shipping one.
    ///
    /// Used to catch a screen reading a hardcoded `.phase0`: every detail here
    /// carries a marker string that appears nowhere in production, so a
    /// contradiction shows up as a missing marker rather than as two sentences a
    /// human has to compare.
    ///
    /// `medicineRiskAssessment` stays `.unavailable` on purpose. That is what
    /// makes the session reach the branch that reads a capability's detail line:
    /// with the capability marked available and no adapter behind it, the gate
    /// correctly stays at `.notStarted` and reports nothing at all, so there
    /// would be no wording to check. Availability differences are not what makes
    /// this table detectable — the markers are.
    static let allMarked = CapabilityCatalog(
        availability: [
            .medicineRecognition: .deviceLocal,
            .medicineRiskAssessment: .unavailable,
            .visionOCR: .deviceLocal,
            .coreLocation: .deviceLocal,
            .arrivalReminder: .deviceLocal,
            .careRecordPersistence: .deviceLocal,
            .trustedContacts: .deviceLocal,
            .serverDependency: .online,
        ],
        detail: Dictionary(
            uniqueKeysWithValues: AppCapability.allCases.map { capability in
                (capability, "\(marker)\(capability.displayName)")
            }
        )
    )

    /// The string that must appear whenever `allMarked` is really in force.
    static let marker = "注入目录标记："
}
