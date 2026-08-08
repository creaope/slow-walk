import Combine
import PhotosUI
import SwiftUI
import UIKit

/// User-facing copy for the three lightweight companion demo experiences.
///
/// These experiences are deterministic demos, not real implementations: the
/// route is scripted, the image feedback is a fixed string, and the anti-fraud
/// result is built-in. The wording says "演示" plainly and never claims a real
/// sensor, vision model, or fraud-detection service. It also never uses the
/// disabled-placeholder vocabulary ("尚未接入" / "暂不可用" / "未来提供" /
/// "当前阶段未") — the entries are actionable, not locked.
enum CompanionDemoCopy {
    // MARK: - Live navigation demo route

    static let routeCardTitle = "实景导航"
    static let routeCardDetail =
        "查看一条固定演示路线，手动推进每一步方向与到站提示。"
    static let routeCardStatus = "演示路线"
    static let routePageTitle = "演示路线"
    static let routeEntryTitle = "查看演示路线"
    static let routeEntryHint = "打开一条固定演示路线，手动推进每一步。"
    static let routeDisclaimer =
        "这是一条固定演示路线，不使用真实定位，由按钮推进每一步。"

    // MARK: - Image feedback demo

    static let imageFeedbackCardTitle = "图片反馈"
    static let imageFeedbackCardDetail =
        "从相册选择一张图片，查看固定的演示反馈。"
    static let imageFeedbackCardStatus = "演示反馈"
    static let imageFeedbackPageTitle = "图片反馈"
    static let imageFeedbackEntryTitle = "查看演示反馈"
    static let imageFeedbackEntryHint =
        "从相册选择一张图片，查看固定的演示反馈。"
    static let imageFeedbackDisclaimer =
        "选择图片后展示固定的演示反馈，不调用识别服务，也不上传图片。"

    // MARK: - Anti-fraud demo

    static let antiFraudCardTitle = "防诈守护"
    static let antiFraudCardDetail =
        "查看一条演示可疑信息，了解演示风险提示。"
    static let antiFraudCardStatus = "演示结果"
    static let antiFraudPageTitle = "防诈守护"
    static let antiFraudEntryTitle = "查看演示结果"
    static let antiFraudEntryHint =
        "查看一条演示可疑信息，了解演示风险提示。"
    static let antiFraudDisclaimer =
        "这是一条固定演示信息，检查结果也是演示用的，不是真实诈骗检测能力。"

    /// Phrases a demo entry must never show. The hub cards and demo pages are
    /// actionable demos, so the disabled-placeholder vocabulary is forbidden.
    static let forbiddenPhrases: [String] = [
        "尚未接入",
        "暂不可用",
        "未来提供",
        "当前阶段未",
    ]

    /// Every user-facing string this type owns, so a test can sweep them all
    /// for the forbidden placeholder vocabulary at once.
    static let allUserFacingStrings: [String] = [
        routeCardTitle,
        routeCardDetail,
        routeCardStatus,
        routePageTitle,
        routeEntryTitle,
        routeEntryHint,
        routeDisclaimer,
        imageFeedbackCardTitle,
        imageFeedbackCardDetail,
        imageFeedbackCardStatus,
        imageFeedbackPageTitle,
        imageFeedbackEntryTitle,
        imageFeedbackEntryHint,
        imageFeedbackDisclaimer,
        antiFraudCardTitle,
        antiFraudCardDetail,
        antiFraudCardStatus,
        antiFraudPageTitle,
        antiFraudEntryTitle,
        antiFraudEntryHint,
        antiFraudDisclaimer,
    ]
}

// MARK: - Live navigation demo route

/// One scripted waypoint on the demo route.
struct DemoRouteWaypoint: Equatable, Hashable, Identifiable {
    let id: Int
    let place: String
    let direction: String
    let distance: String
    let note: String
}

/// A deterministic, manually-advanced demo route.
///
/// No CoreLocation, no map SDK, no network. The route is a fixed list of
/// waypoints and the only input is `advance()`, so the demo is fully
/// reproducible for a judge and for tests.
@MainActor
final class DemoRouteModel: ObservableObject {
    @Published private(set) var currentIndex: Int = 0
    let waypoints: [DemoRouteWaypoint]

    init(waypoints: [DemoRouteWaypoint] = DemoRouteModel.defaultRoute) {
        self.waypoints = waypoints
    }

    var current: DemoRouteWaypoint {
        waypoints[currentIndex]
    }

    var isAtDestination: Bool {
        currentIndex >= waypoints.count - 1
    }

    var progressLabel: String {
        "第 \(currentIndex + 1) 步，共 \(waypoints.count) 步"
    }

    func advance() {
        guard !isAtDestination else { return }
        currentIndex += 1
    }

    func restart() {
        currentIndex = 0
    }

    static let defaultRoute: [DemoRouteWaypoint] = [
        DemoRouteWaypoint(
            id: 0,
            place: "家门口",
            direction: "向东走",
            distance: "距离路口约 80 米",
            note: "出门前再确认一次带了钥匙和今天的药。"
        ),
        DemoRouteWaypoint(
            id: 1,
            place: "路口",
            direction: "右转",
            distance: "距离药房约 120 米",
            note: "过马路前先看红绿灯，不着急。"
        ),
        DemoRouteWaypoint(
            id: 2,
            place: "药房",
            direction: "直行",
            distance: "距离社区中心约 60 米",
            note: "取到药后，再核对一次药名。"
        ),
        DemoRouteWaypoint(
            id: 3,
            place: "社区中心",
            direction: "已到达",
            distance: "目的地",
            note: "今天的目的地到了，可以休息一下。"
        ),
    ]
}

struct DemoRouteView: View {
    @StateObject private var model = DemoRouteModel()

    var body: some View {
        List {
            Section {
                Label(CompanionDemoCopy.routeCardTitle, systemImage: "viewfinder")
                    .font(.headline)
                Text(CompanionDemoCopy.routeDisclaimer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("当前位置") {
                LabeledContent("位置", value: model.current.place)
                LabeledContent("下一步方向", value: model.current.direction)
                LabeledContent("距离提示", value: model.current.distance)
                Label {
                    Text(model.current.note)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }

            Section("路线进度") {
                LabeledContent("进度", value: model.progressLabel)

                if model.isAtDestination {
                    Label(
                        "已到达演示目的地",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.tint)
                } else {
                    Button {
                        model.advance()
                    } label: {
                        Label("推进到下一步", systemImage: "arrow.forward.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                }

                Button("重新走一遍") {
                    model.restart()
                }
            }

            Section {
                DemoDataFooter()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(CompanionDemoCopy.routePageTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Image feedback demo

/// State machine for the image-feedback demo.
///
/// The selected image data lives in the view; this model only tracks the demo
/// phase so the transition (picked → feedback shown) is testable without a
/// `UIImage`.
@MainActor
final class ImageFeedbackDemoModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case picked
        case feedbackShown
    }

    @Published private(set) var phase: Phase = .idle

    var hasPickedImage: Bool { phase != .idle }
    var isShowingFeedback: Bool { phase == .feedbackShown }

    func imagePicked() {
        phase = .picked
    }

    func showDemoFeedback() {
        phase = .feedbackShown
    }

    func reset() {
        phase = .idle
    }

    static let demoFeedbackTitle = "演示反馈"
    static let demoFeedbackBody =
        "这是固定的演示反馈，不是真实视觉模型的识别结果。演示中假设：包装上可能印有药品名称与剂量文字。"
}

struct ImageFeedbackDemoView: View {
    @StateObject private var model = ImageFeedbackDemoModel()
    @State private var selectedItem: PhotosPickerItem?
    @State private var imageData: Data?

    var body: some View {
        List {
            Section {
                Label(
                    CompanionDemoCopy.imageFeedbackCardTitle,
                    systemImage: "photo"
                )
                .font(.headline)
                Text(CompanionDemoCopy.imageFeedbackDisclaimer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("选择图片") {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Label("从相册选择图片", systemImage: "photo.on.rectangle")
                }
                .accessibilityHint("打开相册选择一张图片。")
            }

            if let imageData, let uiImage = UIImage(data: imageData) {
                Section("已选图片") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .accessibilityLabel("已选择的图片预览")
                }
            }

            if model.isShowingFeedback {
                Section {
                    Label(
                        ImageFeedbackDemoModel.demoFeedbackTitle,
                        systemImage: "sparkles"
                    )
                    .font(.headline)

                    Text(ImageFeedbackDemoModel.demoFeedbackBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("演示反馈")
                }
            }

            Section {
                DemoDataFooter()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(CompanionDemoCopy.imageFeedbackPageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(
                    type: Data.self
                ) {
                    imageData = data
                    model.imagePicked()
                    model.showDemoFeedback()
                }
            }
        }
    }
}

// MARK: - Anti-fraud demo

/// One built-in demo risk finding.
struct AntiFraudDemoFinding: Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let detail: String
}

/// A deterministic anti-fraud demo.
///
/// Holds one fixed suspicious message and produces a fixed list of demo
/// findings on `check()`. No backend, no LLM, and no claim of real detection.
@MainActor
final class AntiFraudDemoModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checked
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var findings: [AntiFraudDemoFinding] = []

    var hasChecked: Bool { phase == .checked }

    func check() {
        findings = AntiFraudDemoModel.demoFindings
        phase = .checked
    }

    func reset() {
        findings = []
        phase = .idle
    }

    static let sampleMessage = """
    【温馨提示】您的账户存在异常，请立即点击下方链接验证身份，\
    并在 10 分钟内把收到的验证码发给我们，否则账户将被冻结，\
    请尽快转账到安全账户配合核查。
    """

    static let demoFindings: [AntiFraudDemoFinding] = [
        AntiFraudDemoFinding(
            id: "verificationCode",
            title: "索要验证码",
            detail: "对方要求提供验证码。验证码不能告诉任何人。"
        ),
        AntiFraudDemoFinding(
            id: "urgentTransfer",
            title: "催促立即转账",
            detail: "对方催促在很短时间内转账到所谓安全账户，这是常见话术。"
        ),
        AntiFraudDemoFinding(
            id: "strangeLink",
            title: "陌生链接",
            detail: "信息中带有不明链接，不要点击，也不要在其中填写任何信息。"
        ),
    ]
}

struct AntiFraudDemoView: View {
    @StateObject private var model = AntiFraudDemoModel()

    var body: some View {
        List {
            Section {
                Label(
                    CompanionDemoCopy.antiFraudCardTitle,
                    systemImage: "shield"
                )
                .font(.headline)
                Text(CompanionDemoCopy.antiFraudDisclaimer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("演示信息") {
                Text(AntiFraudDemoModel.sampleMessage)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("检查") {
                if model.hasChecked {
                    Label(
                        "演示结果",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.orange)

                    ForEach(model.findings) { finding in
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(finding.title)
                                    .fontWeight(.semibold)
                                Text(finding.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    Button("重新检查") {
                        model.reset()
                    }
                } else {
                    Button {
                        model.check()
                    } label: {
                        Label("开始检查", systemImage: "shield.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                }
            }

            Section {
                DemoDataFooter()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(CompanionDemoCopy.antiFraudPageTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
