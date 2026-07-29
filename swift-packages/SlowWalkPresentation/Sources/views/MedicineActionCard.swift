import SwiftUI
import SlowWalkDomain

/// Primary action card displaying the medicine assessment result.
/// State and badge level are derived from the DTO internally, ensuring
/// they never diverge.
public struct MedicineActionCard: View {
    let input: MedicineAssessDTO
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(input: MedicineAssessDTO) {
        self.input = input
    }

    private var state: MedicineDisplayState {
        StateMapper.map(input)
    }

    private var badgeLevel: DisplayRiskLevel {
        input.currentRisk
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            contentSection
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("用药评估结果卡片")
    }

    private var headerSection: some View {
        HStack {
            RiskLevelBadge(level: badgeLevel)
            Spacer()
            stateIcon
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .loading:
            ProgressView()
                .scaleEffect(0.8)
        case .timeout, .normalSuccess:
            Image(systemName: state == .timeout ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(state == .timeout ? .orange : .green)
        case .redRisk:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .healthWarning, .knowledgeWarning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .ambiguous:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch state {
        case .loading:
            loadingContent
        case .timeout:
            timeoutContent
        case .redRisk:
            redRiskContent
        case .healthWarning:
            healthWarningContent
        case .knowledgeWarning:
            knowledgeWarningContent
        case .ambiguous:
            ambiguousContent
        case .normalSuccess:
            normalContent
        }
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正在分析用药信息…")
                .font(.headline)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            ProgressView()
        }
        .accessibilityLabel("加载中")
    }

    private var timeoutContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("请求超时")
                .font(.headline)
                .foregroundStyle(.orange)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            Text("网络连接不稳定，请检查网络后重试。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        .accessibilityLabel("请求超时")
    }

    private var redRiskContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(input.primaryMessage)
                .font(.headline)
                .foregroundStyle(.red)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            if let warnings = input.actionCard?.warnings, !warnings.isEmpty {
                ForEach(warnings.prefix(3), id: \.self) { warning in
                    Text("• \(warning)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                }
            }
        }
        .accessibilityLabel("高风险警告")
    }

    private var healthWarningContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("健康提示")
                .font(.headline)
                .foregroundStyle(.orange)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            Text("根据您的健康状况，请注意以下事项。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        .accessibilityLabel("健康提示")
    }

    private var knowledgeWarningContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("数据来源提示")
                .font(.headline)
                .foregroundStyle(.orange)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            Text(input.primaryMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        .accessibilityLabel("数据来源提示")
    }

    private var ambiguousContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("识别结果不明确")
                .font(.headline)
                .foregroundStyle(.yellow)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            Text("请手动确认药品信息，或重新拍照识别。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        .accessibilityLabel("识别结果不明确")
    }

    private var normalContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(input.primaryMessage)
                .font(.headline)
                .foregroundStyle(.primary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            if let warnings = input.actionCard?.warnings, !warnings.isEmpty {
                ForEach(warnings.prefix(2), id: \.self) { warning in
                    Text("• \(warning)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                }
            }
        }
        .accessibilityLabel("用药安全")
    }

    #if canImport(UIKit)
    private var cardBackground: Color {
        Color(uiColor: .systemBackground)
    }
    private var borderColor: Color {
        Color(uiColor: .separator)
    }
    #else
    private var cardBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
    private var borderColor: Color {
        Color.gray.opacity(0.3)
    }
    #endif
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            MedicineActionCard(input: .loading())
            MedicineActionCard(input: .timeout())
            MedicineActionCard(input: MedicineAssessDTO(
                currentRisk: .highRed,
                primaryMessage: "该药品与您当前用药存在严重冲突",
                actionCard: ActionCard(
                    title: "严重药物相互作用",
                    primaryInstruction: "请勿同时服用这两种药物，至少间隔 2 小时",
                    warnings: ["可能增加出血风险", "监测血压"],
                    recommendedActions: [],
                    riskLevel: .red,
                    sourceReferences: [],
                    mustConfirmMedicine: true,
                    generatedAt: Date()
                )
            ))
            MedicineActionCard(input: MedicineAssessDTO(
                hasHealthAlert: true,
                primaryMessage: "根据您的肾功能状况，剂量需要调整"
            ))
            MedicineActionCard(input: MedicineAssessDTO(
                hasSourceWarning: true,
                primaryMessage: "本次数据来源为用户贡献，仅供参考"
            ))
            MedicineActionCard(input: MedicineAssessDTO(
                isAmbiguousResult: true,
                primaryMessage: "无法完全确认药品身份"
            ))
            MedicineActionCard(input: MedicineAssessDTO(
                currentRisk: .lowGreen,
                primaryMessage: "药品安全，按医嘱服用"
            ))
        }
        .padding()
    }
    #if canImport(UIKit)
    .background(Color(.systemGroupedBackground))
    #else
    .background(Color(nsColor: .underPageBackgroundColor))
    #endif
}
