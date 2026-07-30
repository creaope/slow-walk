import Foundation

/// Every user-facing string for the companion flow.
///
/// Wording rules this file must keep (from the product requirements):
/// - Never blame the person. A photo that could not be read is the app's
///   limitation to state plainly, not the person's mistake.
/// - Never infantilise. No "be good", no "listen to us", no pet names.
/// - Never assume a family structure. No "ask your child" or "ask your
///   daughter"; say "someone you trust" and let the person decide who.
/// - Always say what happened, then what to do first, in that order.
/// - On a failed read, offer a recovery path. Never offer a medicine
///   conclusion, dosage, or safety verdict.
/// - Never describe a capability this build does not have. A sentence about
///   reading a photo, following a route, or reminding on arrival is a claim
///   about the world; it may only be written when the `CapabilityCatalog` in
///   force says the capability is real. Where wording depends on a capability,
///   the catalog is passed in by the caller — this type holds none of its own,
///   so the wording always describes the same build the flow is running.
///
/// DEMO DATA — NOT FOR CLINICAL USE
enum CompanionCopy {
    static let demoDataNotice = "DEMO DATA — NOT FOR CLINICAL USE"

    // This type deliberately holds no `CapabilityCatalog`.
    //
    // It used to own a `static let capabilities: CapabilityCatalog = .phase0`,
    // which made a second source of truth: `CompanionSessionModel` took an
    // injected catalog while every screen read this fixed one. Injecting a
    // different catalog then changed the session's behaviour and left all the
    // wording describing the shipping build — the exact contradiction the
    // single-source requirement exists to prevent, and invisible in tests
    // because both paths agreed by default.
    //
    // Functions whose wording depends on a capability now receive the catalog
    // (or the one availability they need) from their caller. The default lives
    // once, in `AppEnvironment`.

    /// Short label for the current step, used in summaries and VoiceOver.
    static func stepLabel(for state: CompanionFlowState) -> String {
        switch state {
        case .notStarted:
            "尚未开始"
        case .preDepartureCheck:
            "出门前确认"
        case let .scanningMedicine(attempt):
            attempt.isAwaitingRecovery ? "需要再试一次" : "正在模拟识别"
        case .awaitingMedicineConfirmation:
            "请确认药名"
        case .awaitingMedicineAssessment:
            "尚未完成风险评估"
        case .travelling:
            "出行途中"
        case .approachingStop:
            "即将到站"
        case let .completed(completion):
            switch completion {
            case .arrivedSafely: "已安全结束"
            case .endedEarly: "已提前结束"
            }
        }
    }

    /// What happened. States the situation without evaluating the person.
    ///
    /// Takes the capability table because one of its branches — the assessment
    /// gate — describes what the app can do. The caller supplies the same table
    /// the session is running against, so the sentence a person reads cannot
    /// describe a different build from the one deciding their flow.
    static func situation(
        for state: CompanionFlowState,
        capabilities: CapabilityCatalog
    ) -> String {
        switch state {
        case .notStarted:
            "今天的陪伴还没有开始。"
        case .preDepartureCheck:
            "出门前，我们一起把要带的东西过一遍。"
        case let .scanningMedicine(attempt):
            if let setback = attempt.setback {
                setbackSituation(setback)
            } else if attempt.attemptNumber == 1 {
                // Says "模拟识别", not "正在读取照片": no photo is read.
                // `.medicineRecognition` is `.simulated`, and this sentence
                // must not outrun it.
                "正在按演示脚本模拟识别药名，本阶段不读取照片。"
            } else {
                "正在重新模拟识别药名，本阶段不读取照片。"
            }
        case let .awaitingMedicineConfirmation(prompt):
            switch prompt.origin {
            case .readFromPhoto:
                "演示脚本给出了几个相近的药名，还不能确定是哪一个。"
            case .chosenFromFrequentList:
                "已经打开常用药名列表。"
            }
        case let .awaitingMedicineAssessment(gate):
            assessmentGateSituation(gate, capabilities: capabilities)
        case .travelling:
            // Says nothing about recording a route: `.coreLocation` is
            // unavailable, so no route exists to record.
            "出行步骤已经开始。本阶段使用演示位置，不记录真实路线。"
        case .approachingStop:
            "这是演示中的“即将到站”步骤，由手动操作触发。"
        case let .completed(completion):
            switch completion {
            case .arrivedSafely:
                "今天的行程已经结束。"
            case .endedEarly:
                "这次陪伴已经结束，随时可以重新开始。"
            }
        }
    }

    /// What to do first. One action, stated plainly.
    static func nextStep(for state: CompanionFlowState) -> String {
        switch state {
        case .notStarted:
            "准备好以后，点击“开始陪伴”。"
        case .preDepartureCheck:
            "先确认要带的药，再出门。"
        case let .scanningMedicine(attempt):
            if attempt.setback != nil {
                "可以重新试一次，也可以直接从常用药名里选。"
            } else {
                "请稍等一下。"
            }
        case let .awaitingMedicineConfirmation(prompt):
            switch prompt.origin {
            case .readFromPhoto:
                "请看一下药盒，选出对得上的那一个。"
            case .chosenFromFrequentList:
                "请选出这次要用的药。"
            }
        case .awaitingMedicineAssessment:
            // Never "先看完提示再继续出发": there is no prompt to read and no
            // departure to make.
            "可以重新选择药名，或者先结束这次陪伴。"
        case .travelling:
            // Never "到站前会提前提醒": `.arrivalReminder` is unavailable.
            "本阶段不会自动提醒到站，需要手动进入下一步。"
        case .approachingStop:
            "可以先收好东西，准备下车。"
        case .completed:
            "记录已经保存在本次运行中，可以在守护记录里查看。"
        }
    }

    /// Why this step exists. Never a medical claim.
    static func reason(for state: CompanionFlowState) -> String? {
        switch state {
        case .preDepartureCheck:
            "出门前确认一次，路上就不用再翻找。"
        case let .scanningMedicine(attempt):
            attempt.setback != nil
                ? "药名要确认清楚，才能给出对得上的提示。"
                : nil
        case .awaitingMedicineConfirmation:
            "不同的药提示不一样，确认之后才准确。"
        case .awaitingMedicineAssessment:
            "确认药名只说明这是哪一盒药，还不能说明能不能吃。"
        case .approachingStop:
            "提前一点准备，下车时不用着急。"
        case .notStarted, .travelling, .completed:
            nil
        }
    }

    /// What the assessment gate says, derived from the capability table.
    ///
    /// This is the one screen that must never overstate: a person held here has
    /// confirmed a medicine and may reasonably expect to be told something
    /// about it. The wording therefore states twice over that nothing was
    /// assessed — once as the situation, once as the reason.
    ///
    /// The explanatory line comes from the passed-in catalog. When
    /// `.medicineRiskAssessment` becomes `.deviceLocal`, that catalog's detail
    /// changes and this sentence follows, rather than keeping a "尚未接入"
    /// explanation written into the wording itself.
    private static func assessmentGateSituation(
        _ gate: MedicineAssessmentGate,
        capabilities: CapabilityCatalog
    ) -> String {
        let name = gate.confirmed.candidate.displayName
        switch gate.progress {
        case .notStarted:
            return "已确认药名：\(name)。正在等待正式的用药风险评估。"
        case let .couldNotAssess(setback):
            switch setback {
            case .notWiredUpYet:
                let detail = capabilities.detail(of: .medicineRiskAssessment)
                    ?? "设备内评估将在下一阶段接入。"
                return "已确认药名：\(name)，但本阶段尚未完成风险评估。\(detail)"
            }
        }
    }

    private static func setbackSituation(_ setback: MedicineReadSetback) -> String {
        switch setback {
        case .textNotLegible:
            "演示脚本这次没有给出可用的药名文字。"
        case .noMedicineNameFound:
            "演示脚本这次没有给出药名。"
        }
    }

    // MARK: - Recovery and actions

    static let retryPhotoTitle = "重新试一次"
    static let chooseFromListTitle = "从常用药名里选"
    static let readAloudAgainTitle = "再说一遍"
    static let whyThisHappenedTitle = "看看原因"
    static let contactSomeoneTitle = "联系信任的人"
    static let remindLaterTitle = "稍后提醒"

    static let startCompanionTitle = "开始陪伴"
    static let continueCompanionTitle = "继续陪伴"
    static let beginMedicineReadTitle = "确认要带的药"
    static let reconsiderMedicineTitle = "重新选择药名"
    static let approachStopTitle = "模拟：即将到站"
    static let arriveSafelyTitle = "已安全到达"
    static let endEarlyTitle = "先结束这次陪伴"

    /// Why a person might contact someone, without naming a relative.
    static let contactSomeoneHint = "可以联系一位您信任的人一起看看。"
}
