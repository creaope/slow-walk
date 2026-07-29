import SwiftUI
import SlowWalkDomain
import SlowWalkAPIContracts

/// Demo view for displaying a complete medicine assessment flow.
@available(iOS 17.0, macOS 14.0, *)
public struct MedicineDemoView: View {
    @State private var assessDTO: MedicineAssessDTO
    @State private var isLoading = false

    public init(assessDTO: MedicineAssessDTO = .loading()) {
        _assessDTO = State(initialValue: assessDTO)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MedicineActionCard(input: assessDTO)

                    actionButtonsSection
                }
                .padding()
            }
            .navigationTitle("用药评估")
            .refreshable {
                await simulateRefresh()
            }
        }
        .task {
            await loadInitialAssessment()
        }
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 8) {
            Button {
                Task { await simulateRefresh() }
            } label: {
                Text("重新评估")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)

            if assessDTO.isCancelled {
                Button {
                    assessDTO = .loading()
                } label: {
                    Text("取消操作")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(isLoading)
    }

    private func loadInitialAssessment() async {
        isLoading = true
        assessDTO = .loading()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        assessDTO = MedicineAssessDTO(
            currentRisk: .lowGreen,
            primaryMessage: "药品安全，按医嘱服用",
            actionCard: ActionCard(
                title: "用药安全",
                primaryInstruction: "按医嘱服用，注意观察身体反应",
                warnings: [],
                recommendedActions: [],
                riskLevel: .green,
                sourceReferences: [],
                mustConfirmMedicine: false,
                generatedAt: Date()
            )
        )
        isLoading = false
    }

    private func simulateRefresh() async {
        isLoading = true
        assessDTO = .loading()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        assessDTO = MedicineAssessDTO(
            currentRisk: .lowGreen,
            primaryMessage: "药品安全，按医嘱服用"
        )
        isLoading = false
    }
}

#Preview {
    MedicineDemoView()
}
