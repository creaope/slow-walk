import Testing
import Foundation
@testable import SlowWalkApp

/// Tests for the three lightweight companion demo experiences.
///
/// These demos are deterministic by design: a scripted route advanced by a
/// button, a fixed image-feedback string, and a built-in anti-fraud sample.
/// The tests prove the state machines advance as a judge will see them, and
/// that none of the demo copy reintroduces the disabled-placeholder
/// vocabulary ("尚未接入" / "暂不可用" / "未来提供" / "当前阶段未") that the
/// demo hub replaced.
@MainActor
struct CompanionDemoExperiencesTests {

    // MARK: - Live navigation demo route

    @Test func routeStartsAtFirstWaypointAndIsNotAtDestination() {
        let model = DemoRouteModel()

        #expect(model.currentIndex == 0)
        #expect(model.isAtDestination == false)
        #expect(model.current.id == 0)
        #expect(model.progressLabel == "第 1 步，共 4 步")
    }

    @Test func routeAdvancesOneStepAtATime() {
        let model = DemoRouteModel()

        model.advance()
        #expect(model.currentIndex == 1)
        #expect(model.current.place == "路口")
        #expect(model.isAtDestination == false)
    }

    @Test func routeReachesDestinationAndStops() {
        let model = DemoRouteModel(waypoints: DemoRouteModel.defaultRoute)

        model.advance()
        model.advance()
        model.advance()
        #expect(model.currentIndex == 3)
        #expect(model.isAtDestination == true)
        #expect(model.current.place == "社区中心")

        // Advancing past the destination is a no-op: the demo stays at the
        // last waypoint rather than crashing or wrapping.
        model.advance()
        #expect(model.currentIndex == 3)
        #expect(model.isAtDestination == true)
    }

    @Test func routeRestartReturnsToFirstWaypoint() {
        let model = DemoRouteModel()
        model.advance()
        model.advance()

        model.restart()
        #expect(model.currentIndex == 0)
        #expect(model.current.place == "家门口")
        #expect(model.isAtDestination == false)
    }

    @Test func defaultRouteHasFourWaypointsEndingAtDestination() {
        let route = DemoRouteModel.defaultRoute
        #expect(route.count == 4)
        #expect(route.last?.place == "社区中心")
    }

    // MARK: - Image feedback demo state

    @Test func imageFeedbackStartsIdle() {
        let model = ImageFeedbackDemoModel()
        #expect(model.phase == .idle)
        #expect(model.hasPickedImage == false)
        #expect(model.isShowingFeedback == false)
    }

    @Test func pickingImageEntersPickedStateBeforeFeedback() {
        let model = ImageFeedbackDemoModel()

        model.imagePicked()
        #expect(model.phase == .picked)
        #expect(model.hasPickedImage == true)
        #expect(model.isShowingFeedback == false)
    }

    @Test func showingDemoFeedbackAfterPickDisplaysFeedback() {
        let model = ImageFeedbackDemoModel()
        model.imagePicked()

        model.showDemoFeedback()
        #expect(model.phase == .feedbackShown)
        #expect(model.hasPickedImage == true)
        #expect(model.isShowingFeedback == true)
    }

    @Test func imageFeedbackResetReturnsToIdle() {
        let model = ImageFeedbackDemoModel()
        model.imagePicked()
        model.showDemoFeedback()

        model.reset()
        #expect(model.phase == .idle)
        #expect(model.hasPickedImage == false)
        #expect(model.isShowingFeedback == false)
    }

    @Test func demoFeedbackDoesNotClaimRealRecognition() {
        let body = ImageFeedbackDemoModel.demoFeedbackBody
        #expect(body.contains("演示"))
        #expect(body.contains("不是真实视觉模型的识别结果"))
    }

    // MARK: - Anti-fraud demo result

    @Test func antiFraudStartsIdleWithNoFindings() {
        let model = AntiFraudDemoModel()
        #expect(model.phase == .idle)
        #expect(model.hasChecked == false)
        #expect(model.findings.isEmpty)
    }

    @Test func checkingProducesDemoFindings() {
        let model = AntiFraudDemoModel()

        model.check()
        #expect(model.hasChecked == true)
        #expect(model.findings == AntiFraudDemoModel.demoFindings)
        #expect(model.findings.count == 3)
    }

    @Test func demoFindingsCoverTheThreeCanonicalRiskPatterns() {
        let titles = AntiFraudDemoModel.demoFindings.map(\.title)
        #expect(titles.contains("索要验证码"))
        #expect(titles.contains("催促立即转账"))
        #expect(titles.contains("陌生链接"))
    }

    @Test func sampleMessageContainsVerificationCodeTransferAndLink() {
        let message = AntiFraudDemoModel.sampleMessage
        #expect(message.contains("验证码"))
        #expect(message.contains("转账"))
        #expect(message.contains("链接"))
    }

    @Test func antiFraudResetClearsFindings() {
        let model = AntiFraudDemoModel()
        model.check()

        model.reset()
        #expect(model.phase == .idle)
        #expect(model.hasChecked == false)
        #expect(model.findings.isEmpty)
    }

    // MARK: - No disabled-placeholder vocabulary in the demo path

    @Test func demoCardCopyAvoidsDisabledPlaceholderVocabulary() {
        for phrase in CompanionDemoCopy.forbiddenPhrases {
            for string in CompanionDemoCopy.allUserFacingStrings {
                #expect(
                    string.contains(phrase) == false,
                    "Demo copy \"\(string)\" contains forbidden phrase \"\(phrase)\""
                )
            }
        }
    }

    @Test func demoModelCopyAvoidsDisabledPlaceholderVocabulary() {
        let modelStrings: [String] = [
            ImageFeedbackDemoModel.demoFeedbackTitle,
            ImageFeedbackDemoModel.demoFeedbackBody,
            AntiFraudDemoModel.sampleMessage,
        ]
        + AntiFraudDemoModel.demoFindings.flatMap { [$0.title, $0.detail] }
        + DemoRouteModel.defaultRoute.flatMap {
            [$0.place, $0.direction, $0.distance, $0.note]
        }

        for phrase in CompanionDemoCopy.forbiddenPhrases {
            for string in modelStrings {
                #expect(
                    string.contains(phrase) == false,
                    "Demo model copy \"\(string)\" contains forbidden phrase \"\(phrase)\""
                )
            }
        }
    }

    /// The companion hub must not reintroduce the disabled "暂不可用" lock
    /// cards, and the three demo destinations must be wired as actionable
    /// entries. A source-level guard because SwiftUI view bodies cannot be
    /// asserted on directly — the same approach used by the presentation
    /// package's structural tests.
    @Test func companionHubDoesNotShowDisabledPlaceholderCards() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SlowWalkApp")
            .appendingPathComponent("Features")
            .appendingPathComponent("Companion")
            .appendingPathComponent("CompanionView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // The disabled lock-card vocabulary is gone from the hub.
        #expect(source.contains("暂不可用") == false)
        #expect(source.contains("尚未接入") == false)
        #expect(source.contains("未来提供") == false)
        #expect(source.contains("当前阶段未") == false)
        #expect(source.contains("Label(\"暂不可用\", systemImage: \"lock\")") == false)

        // The three demo entries are wired as actionable destinations.
        #expect(source.contains(".demoRoute"))
        #expect(source.contains(".imageFeedback"))
        #expect(source.contains(".antiFraud"))
    }
}
