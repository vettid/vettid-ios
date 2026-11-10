import Foundation
import Observation
import VettIDData

/// TEST ONLY. A pairing (ANDROID-PLAN 0.1.53 AA2) for view-model tests and the screen catalog: set [state] to put the screen at a
/// stage; calls are recorded in [calls] (`start`, `start:desktop`, `approve:<seconds>`, `reject`, `cancel`, `leave`, `acknowledge`).
/// Mirrors vettid-android `FakePairing`.
@MainActor
@Observable
public final class FakePairing: PairingRepository {
    public var state = PairingState()

    @ObservationIgnored public var calls: [String] = []

    public init() {}

    public func start(_ role: PairRole) async {
        calls.append(role == .agent ? "start" : "start:\(role.wire)")
        state.role = role
    }

    public func approve(sessionSeconds: Int?) async {
        calls.append("approve:\(sessionSeconds.map(String.init) ?? "nil")")
    }

    public func reject() async {
        calls.append("reject")
        if case .compare = state.stage { state = PairingState(stage: .rejected(told: true)) }
    }

    public func cancel() async { calls.append("cancel") }

    public func leave() { calls.append("leave") }

    public func acknowledge() { calls.append("acknowledge") }
}
