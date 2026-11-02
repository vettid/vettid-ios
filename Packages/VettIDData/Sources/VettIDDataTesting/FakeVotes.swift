import Foundation
import Observation
import VettIDData

/// TEST ONLY. An in-memory Votes repository (IOS-PLAN §4.16) for view-model tests and the screen catalog: [votes] is what
/// `vote.list` answers, [details] what `vote.get` answers by the pair; calls are recorded in [calls]
/// (`cast:<connection>/<proposal>:<choice>`); [fail] makes the next call of a name throw. Mirrors vettid-android
/// `FakeVotes`.
@MainActor
@Observable
public final class FakeVotes: VotesRepository {
    public var votes: [VoteSummary] = []
    public var reconnect: [ReconnectEntry] = []
    public var dropped: [DroppedNotice] = []
    public var problems: [ProblemsNotice] = []
    public var availability: VotesAvailability = .available
    public var load: ListLoad = .loaded
    public var hints: [VoteKey: VoteHint] = [:]
    public var windowNotClosed: WindowNotClosed?
    public var entry: VotesEntry { VoteRules.entry(votes, reconnect: reconnect, availability: availability) }

    @ObservationIgnored public var calls: [String] = []
    @ObservationIgnored public var fail: [String: VaultFailure] = [:]
    /// Any other error the next call of that name throws (once): a ``CancellationError`` (a lock or the app leaving).
    @ObservationIgnored public var failError: [String: any Error] = [:]
    @ObservationIgnored public var details: [VoteKey: VoteDetail] = [:]
    @ObservationIgnored public var evidenceText = #"{"evidence":true}"#
    @ObservationIgnored public var windowIsOpen = false
    /// The password each cast was given (nil: none was needed).
    @ObservationIgnored public var castPasswords: [String?] = []
    @ObservationIgnored public var releasePins: [String] = []
    @ObservationIgnored public var acknowledged: [[String]] = []
    /// What ``checkResults(_:)`` answers.
    @ObservationIgnored public var resultsOutcome: ResultsOutcome = .submitted(.pending)
    /// Runs when ``refresh()`` is asked, before it answers (the vault's list changing meanwhile).
    @ObservationIgnored public var onRefresh: @MainActor () -> Void = {}

    public init() {}

    private static func name(_ k: VoteKey) -> String { "\(k.connectionID)/\(k.proposalID)" }

    private func call(_ name: String) throws {
        calls.append(name)
        if let f = fail.removeValue(forKey: name) { throw f }
        if let e = failError.removeValue(forKey: name) { throw e }
    }

    public func closeWindowNow() async throws {
        try call("closeWindowNow")
        windowNotClosed = nil
    }

    public func refresh() async throws {
        try call("refresh")
        onRefresh()
    }

    public func refreshQuietly() { calls.append("refreshQuietly") }

    public func get(_ key: VoteKey) async throws -> VoteDetail {
        try call("get:\(Self.name(key))")
        guard let d = details[key] else { throw VaultFailure(.notFound, code: "not_found") }
        return d
    }

    public func cast(_ key: VoteKey, choiceID: String, password: String?) async throws -> BallotState {
        castPasswords.append(password)
        try call("cast:\(Self.name(key)):\(choiceID)")
        return .sending
    }

    public func windowOpen() -> Bool { windowIsOpen }

    public func check(_ key: VoteKey) async throws { try call("check:\(Self.name(key))") }

    public func confirm(_ key: VoteKey, mine: Bool) async throws -> BallotState {
        try call("confirm:\(Self.name(key)):\(mine)")
        return mine ? .recorded : .disputed
    }

    public func evidence(_ key: VoteKey) async throws -> String {
        try call("evidence:\(Self.name(key))")
        return evidenceText
    }

    public func release(_ key: VoteKey, pin: String) async throws {
        releasePins.append(pin)
        try call("release:\(Self.name(key))")
    }

    public func acknowledgeDropped(_ connectionIDs: [String]) {
        acknowledged.append(connectionIDs)
        dropped.removeAll { connectionIDs.contains($0.connectionID) }
    }

    public func titleOf(_ key: VoteKey) -> String? { votes.first { $0.key == key }?.title }

    public func siteCheck(_ key: VoteKey) async throws { try call("siteCheck:\(Self.name(key))") }

    public func checkResults(_ key: VoteKey) async throws -> ResultsOutcome {
        try call("checkResults:\(Self.name(key))")
        return resultsOutcome
    }

    public func diagnoseGaveUp(_ key: VoteKey) async { calls.append("diagnoseGaveUp:\(Self.name(key))") }
}
