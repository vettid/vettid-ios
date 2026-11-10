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
    /// The pairing ids approved, the tokens left and the tokens acknowledged.
    @ObservationIgnored public var approvedIDs: [String] = []
    @ObservationIgnored public var leftTokens: [Int?] = []
    @ObservationIgnored public var leftOwners: [Int] = []
    @ObservationIgnored public var owners: [Int] = []
    @ObservationIgnored public var claimedOwners: [Int] = []
    @ObservationIgnored public var rejectedIDs: [String] = []
    @ObservationIgnored public var acknowledgedTokens: [Int] = []

    public init() {}

    public func start(_ role: PairRole, owner: Int) async {
        calls.append(role == .agent ? "start" : "start:\(role.wire)")
        owners.append(owner)
        state.role = role
    }

    public func claim(owner: Int) { claimedOwners.append(owner) }

    public func approve(pairingID: String, sessionSeconds: Int?) async {
        calls.append("approve:\(sessionSeconds.map(String.init) ?? "nil")")
        approvedIDs.append(pairingID)
    }

    public func reject(pairingID: String) async {
        calls.append("reject")
        rejectedIDs.append(pairingID)
        if case .compare = state.stage { state = PairingState(stage: .rejected(told: true)) }
    }

    public func leave(token: Int?, owner: Int) {
        calls.append("leave")
        leftTokens.append(token)
        leftOwners.append(owner)
    }

    public func acknowledge() { calls.append("acknowledge") }

    public func acknowledge(token: Int, owner: Int) {
        calls.append("acknowledge")
        acknowledgedTokens.append(token)
    }
}
