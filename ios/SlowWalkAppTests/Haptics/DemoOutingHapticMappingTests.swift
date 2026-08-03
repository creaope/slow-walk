import Foundation
import Testing
@testable import SlowWalkApp

@MainActor
struct DemoOutingHapticMappingTests {

    @Test func alertMomentsMapToHaptics() {
        #expect(DemoOutingHaptic(state: .attentionNeeded) == .attentionNeeded)
        #expect(DemoOutingHaptic(state: .arrived) == .arrived)
    }

    @Test func silentStatesProduceNoHaptic() {
        #expect(DemoOutingHaptic(state: .idle) == nil)
        #expect(DemoOutingHaptic(state: .travelling) == nil)
        #expect(DemoOutingHaptic(state: .approaching) == nil)
        #expect(DemoOutingHaptic(state: .cancelled) == nil)
        #expect(DemoOutingHaptic(state: .failed(reason: "x")) == nil)
    }
}
