import Foundation
import SlowWalkClientCore
import SlowWalkDomain

/// Interface labels and faithful renderings of canonical enumerations.
///
/// Strict boundary: nothing here invents medical content. Every medical
/// sentence a view shows comes from `ActionCard.title`,
/// `primaryInstruction`, `warnings`, or `sourceReferences`. This type only
/// supplies:
///
/// - section headings ("Risk level", "Recommended actions", "Information
///   sources") that organize canonical content without changing it;
/// - literal readings of canonical enum cases (`RecommendedAction`,
///   `RiskLevel`, `RiskAttentionSemantics`, `ClientFailureKind`);
/// - non-color-only shape and symbol tokens for each reminder level.
///
/// It deliberately contains no reassurance ("no risk", "safe to use"),
/// no prohibition ("do not take", "not recommended") that the canonical card
/// did not state, and no diagnosis, prescription, discontinuation, or
/// permission wording.
public enum MedicinePresentationCopy {
    // MARK: - Demo disclaimer

    /// The canonical demo disclaimer shown by preview and demo callers.
    /// Production assessments never use this value.
    public static let demoDisclaimer =
        "DEMO DATA — NOT FOR CLINICAL USE"

    /// The Chinese sentence shown to users for the canonical demo disclaimer.
    ///
    /// The raw canonical value (`demoDisclaimer`) stays English so the medicine
    /// pipeline's oracle and pass-through rendering are unchanged; this constant
    /// is the display-layer localization only.
    public static let demoDisclaimerDisplayCopy =
        "演示数据，仅用于功能展示，不用于临床用途"

    /// Maps a raw demo disclaimer to the user-visible display string.
    ///
    /// Only the known canonical disclaimer (`demoDisclaimer`) is localized to
    /// Chinese; any other disclaimer is returned **unchanged** so non-canonical
    /// medical wording is never rewritten. `nil` maps to `nil`, which keeps the
    /// "render only when present" contract intact for views that gate on it.
    public static func displayDisclaimer(for raw: String?) -> String? {
        guard let raw else { return nil }
        return raw == demoDisclaimer ? demoDisclaimerDisplayCopy : raw
    }

    // MARK: - Display mapping for known demo canonical medicine names

    /// Known demo canonical medicine names mapped to their Chinese display
    /// forms. This is a display-only layer; canonical identity, equality,
    /// resolver, risk engine, and pipeline semantics are never affected.
    private static let medicineNameDisplayMap: [String: String] = [
        "Acetaminophen": "对乙酰氨基酚",
        "Unable to confirm the medicine": "无法确认药品身份",
    ]

    /// Maps a known demo canonical medicine name to its Chinese display name.
    ///
    /// Unknown names pass through unchanged so non-demo or model-generated
    /// medical content is never rewritten. `nil` maps to `nil`.
    public static func displayMedicineName(
        _ canonicalName: String?
    ) -> String? {
        guard let canonicalName else { return nil }
        return medicineNameDisplayMap[canonicalName] ?? canonicalName
    }

    // MARK: - Display mapping for known demo canonical primary instructions

    /// Known demo canonical primary instructions mapped to Chinese.
    private static let primaryInstructionDisplayMap: [String: String] = [
        "Review the verified source information before use.":
            "使用前请核对已验证的信息来源。",
        "Pause and review the available information.":
            "请暂停并查看现有信息。",
        "Review the medication history with a healthcare professional.":
            "请与医护人员核对用药记录。",
        "Do not take this medicine until a healthcare professional confirms the next step.":
            "在医护人员确认之前，请勿服用此药品。",
        "Retake a clear photo of the front of the medicine box.":
            "请重新拍摄药品包装盒正面清晰照片。",
    ]

    /// Maps a known demo canonical primary instruction to its Chinese display
    /// text. Unknown instructions pass through unchanged; `nil` maps to `nil`.
    public static func displayPrimaryInstruction(
        _ instruction: String?
    ) -> String? {
        guard let instruction else { return nil }
        return primaryInstructionDisplayMap[instruction] ?? instruction
    }

    // MARK: - Display mapping for source document titles

    /// Maps the known demo canonical source document title to its Chinese
    /// display form. Unknown titles pass through unchanged.
    public static func displayDocumentTitle(_ title: String) -> String {
        if title == demoDisclaimer {
            return demoDisclaimerDisplayCopy
        }
        return title
    }

    /// Renders a `SourceReference` for display with Chinese document title
    /// mapping applied.
    ///
    /// When both fields match the known deterministic demo source exactly, the
    /// entire summary is replaced with the canonical Chinese display form so
    /// the user never sees the English catalog identifiers.  Any other
    /// combination falls through to the general `sourceName — documentTitle`
    /// rendering with `displayDocumentTitle` applied to the title portion.
    public static func displaySourceSummary(
        _ reference: SourceReference
    ) -> String {
        if reference.sourceName == "SlowWalk Synthetic Demo Catalog",
           reference.documentTitle == demoDisclaimer
        {
            return "SlowWalk 演示药品目录 — \(demoDisclaimerDisplayCopy)"
        }
        return "\(reference.sourceName) — \(displayDocumentTitle(reference.documentTitle))"
    }

    // MARK: - Display mapping for known demo canonical warnings

    /// Known demo canonical warning strings mapped to Chinese.
    private static let warningDisplayMap: [String: String] = [
        "Do not take this medicine until its identity is confirmed.":
            "药品身份确认前请勿服用。",
        "A risk assessment is not available for the resolved medicine.":
            "未能获取已识别药品的风险评估结果。",
        "More than one medicine matched the recognized text.":
            "识别文字匹配到多个可能的药品。",
        "The available recognition evidence is insufficient.":
            "当前识别证据不足以确认药品。",
        "No medicine in the verified data matched the recognized text.":
            "已验证数据中未找到与识别文字匹配的药品。",
        "The medicine text could not be recognized reliably.":
            "未能可靠识别药品标签文字。",
    ]

    /// Maps a known demo canonical warning to its Chinese display text.
    /// Unknown warnings pass through unchanged; `nil` maps to `nil`.
    ///
    /// The known demo disclaimer is also checked so that canonical
    /// `Medicine.warnings` entries containing `"DEMO DATA — NOT FOR CLINICAL
    /// USE"` are mapped to the same Chinese sentence without duplicating the
    /// disclaimer copy.
    public static func displayWarning(_ warning: String?) -> String? {
        guard let warning else { return nil }
        if let mapped = warningDisplayMap[warning] {
            return mapped
        }
        if warning == demoDisclaimer {
            return demoDisclaimerDisplayCopy
        }
        return warning
    }

    // MARK: - Section headings

    public static let recognitionHeading = "图片识别"
    public static let resolvedMedicineLabel = "识别药品"
    public static let pendingMedicineLabel = "候选药品（待确认）"
    public static let recognizedTextLabel = "识别文字"
    public static let localFallbackRecognitionNotice =
        "在线识别暂不可用，已改用设备内识别。"
    public static let onDeviceOnlyRecognitionNotice =
        "本次仅在设备上识别。"
    public static let riskLevelHeading = "风险等级"
    public static let primaryInstructionHeading =
        "接下来怎么做"
    public static let warningsHeading = "注意事项"
    public static let recommendedActionsHeading =
        "建议措施"
    public static let sourceReferencesHeading =
        "信息来源"
    public static let confirmationRequiredHeading =
        "药品身份未确认"

    /// Shown independently of the confirmation-requirement indicator when
    /// the canonical card's `mustConfirmMedicine` is `true`.
    public static let mustConfirmLabel =
        "请确认药品信息"

    /// Shown when the canonical card has no source references at all, so the
    /// absence is visible instead of silently rendering an empty section.
    public static let noSourceReferencesText =
        "本结果未记录信息来源。"

    /// Describes identity certainty without changing the canonical medicine.
    public static func medicineNameLabel(
        requiresMedicineConfirmation: Bool
    ) -> String {
        requiresMedicineConfirmation
            ? pendingMedicineLabel
            : resolvedMedicineLabel
    }

    /// A non-medical recognition provenance notice.
    ///
    /// All recoverable remote failure reasons intentionally collapse into one
    /// user-facing sentence. Service brands, transport codes, and other
    /// implementation details never cross the presentation boundary.
    public static func recognitionNotice(
        for context: MedicineRecognitionContext
    ) -> String? {
        switch context.source {
        case .remote:
            return nil
        case .localFallback:
            return context.fallbackReason == .onDeviceOnly
                ? onDeviceOnlyRecognitionNotice
                : localFallbackRecognitionNotice
        }
    }

    // MARK: - Progress and lifecycle

    public static let idleText =
        "尚未开始药品评估。"
    public static let recognizingText =
        "正在识别药品标签。"
    public static let assessingText =
        "正在核对药品信息。"
    public static let cancelledText =
        "药品评估已取消。"

    // MARK: - Risk level

    /// The canonical level name. No severity word is added, because the
    /// canonical attention semantics below already carry that meaning.
    public static func levelName(
        _ level: RiskLevel
    ) -> String {
        switch level {
        case .green:
            return "绿色"
        case .yellow:
            return "黄色"
        case .orange:
            return "橙色"
        case .red:
            return "红色"
        }
    }

    /// A literal reading of `RiskAttentionSemantics`, the non-color-only
    /// severity vocabulary Client Core already defines.
    public static func attentionName(
        _ attention: RiskAttentionSemantics
    ) -> String {
        switch attention {
        case .routine:
            return "日常注意"
        case .reviewRequired:
            return "需要复核"
        case .urgentAttention:
            return "紧急关注"
        case .immediateAttention:
            return "立即关注"
        }
    }

    /// SF Symbol per level. Each level gets a distinct silhouette so the four
    /// levels stay distinguishable without color — in particular `yellow`
    /// (triangle) and `orange` (octagon) never share a shape.
    ///
    /// All names verified present in the system symbol library.
    public static func symbolName(
        _ level: RiskLevel
    ) -> String {
        switch level {
        case .green:
            return "checkmark.circle.fill"
        case .yellow:
            return "exclamationmark.triangle.fill"
        case .orange:
            return "exclamationmark.octagon.fill"
        case .red:
            return "hand.raised.fill"
        }
    }

    /// A text shape token rendered next to the badge. It repeats the level
    /// distinction in a third channel, so the level survives color blindness,
    /// a monochrome display, and a symbol that fails to load.
    public static func shapeToken(
        _ level: RiskLevel
    ) -> String {
        switch level {
        case .green:
            return "●"
        case .yellow:
            return "▲"
        case .orange:
            return "◆"
        case .red:
            return "■"
        }
    }

    /// Full VoiceOver reading for a reminder level: heading, canonical level
    /// name, and canonical attention semantics. Color is never the only cue.
    public static func riskAccessibilityLabel(
        _ presentation: RiskPresentation
    ) -> String {
        """
        \(riskLevelHeading): \
        \(levelName(presentation.level)), \
        \(attentionName(presentation.attention))
        """
    }

    // MARK: - Recommended actions

    /// A literal reading of one canonical `RecommendedAction`.
    ///
    /// Each string restates its enum case and nothing more. No action gains
    /// urgency, loses a restriction, or acquires clinical detail in
    /// translation.
    public static func actionName(
        _ action: RecommendedAction
    ) -> String {
        switch action {
        case .followVerifiedSourceInformation:
            return "依照已核实的信息来源"
        case .consultHealthcareProfessional:
            return "咨询医护人员"
        case .notifyFamilyMember:
            return "通知家人"
        case .reviewMedicineSources:
            return "查看药品信息来源"
        case .updateHealthProfile:
            return "更新健康资料"
        case .retakeMedicinePhoto:
            return "重新拍摄药品照片"
        case .doNotTakeUntilMedicineConfirmed:
            return "确认药品前请勿服用"
        case .reviewMedicationHistory:
            return "查看用药记录"
        case .remeasureBodyMetrics:
            return "重新测量身体指标"
        }
    }

    // MARK: - Failure

    /// A literal reading of one canonical `ClientFailureKind`. No failure is
    /// described as a medical outcome.
    public static func failureName(
        _ kind: ClientFailureKind
    ) -> String {
        switch kind {
        case .api:
            return "服务无法完成请求。"
        case .timeout:
            return "请求超时，未收到结果。"
        case .malformedResponse:
            return "返回内容无法读取。"
        case .transportUnavailable:
            return "无法连接服务。"
        case .recognition:
            return "无法识别药品标签。"
        case .unknown:
            return "请求未能完成。"
        }
    }

    /// No risk level, instruction, or action card is implied for a failure.
    public static let noResultAvailableText =
        "未收到药品评估结果。"

    public static let retryButtonTitle = "重试"
    public static let retryAccessibilityHint =
        "重新发起药品评估。"
    public static let confirmMedicineButtonTitle =
        "确认药品"
    public static let confirmMedicineAccessibilityHint =
        "打开药品确认。"

    // MARK: - Source references

    /// Renders one canonical `SourceReference` from its own recorded fields
    /// only. No authority, endorsement, or currency is asserted beyond them.
    public static func sourceSummary(
        _ reference: SourceReference
    ) -> String {
        "\(reference.sourceName) — \(reference.documentTitle)"
    }

    public static func sourceVersionSummary(
        _ reference: SourceReference
    ) -> String {
        "版本 \(reference.versionOrDate)"
    }
}
