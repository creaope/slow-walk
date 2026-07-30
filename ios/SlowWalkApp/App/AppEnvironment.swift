import Foundation
import SlowWalkDomain

/// The app's composition root.
///
/// Platform implementations and demo doubles are assembled here and handed to
/// features. Views and models never construct a clock, a store, or a network
/// client themselves.
///
/// This stage wires demo data only. `ios/README.md` records which Apple
/// adapters — Vision, CoreLocation, URLSession, protected storage, speech —
/// are still unimplemented; none of them are referenced here.
@Observable
@MainActor
final class AppEnvironment {
    let clock: any SlowWalkDomain.Clock
    let plan: TodayPlan
    let careRecords: InMemoryCareRecordStore
    let companion: CompanionSessionModel

    /// What this build can really do — the app's single capability source.
    ///
    /// Every screen that states a capability reads it from here, or from
    /// `companion.capabilities`, which is this same value. `CapabilityCatalog`
    /// has no static default anywhere else and no view names `.phase0`: the
    /// default is chosen once, on this initialiser's parameter, so a test can
    /// describe a different build by constructing one environment and have the
    /// whole app — behaviour and wording together — follow it.
    let capabilities: CapabilityCatalog

    init(
        clock: any SlowWalkDomain.Clock = AppSystemClock(),
        plan: TodayPlan = .demo,
        simulator: MockMedicineScanSimulator = .demo,
        capabilities: CapabilityCatalog = .phase0
    ) {
        self.clock = clock
        self.plan = plan
        self.capabilities = capabilities

        let store = InMemoryCareRecordStore(clock: clock)
        careRecords = store
        companion = CompanionSessionModel(
            records: store,
            simulator: simulator,
            plan: plan,
            capabilities: capabilities
        )
    }

    /// Deterministic environment for previews.
    static func preview(
        fixedDate: Date = Date(timeIntervalSince1970: 1_753_000_000)
    ) -> AppEnvironment {
        AppEnvironment(clock: AppFixedClock(fixedDate: fixedDate))
    }
}
