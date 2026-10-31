import Foundation
import Observation

/// Votes where there are none (a screen's default, so that it needs no vault of votes to be built): empty, never
/// available, and every request is "not supported". Nothing is shown and nothing is sent. Mirrors vettid-android
/// `NoVotes`.
@MainActor
@Observable
public final class NoVotes: VotesRepository {
    public let votes: [VoteSummary] = []
    public let reconnect: [ReconnectEntry] = []
    public let dropped: [DroppedNotice] = []
    public let problems: [ProblemsNotice] = []
    public let availability: VotesAvailability = .unsupported
    public let load: ListLoad = .notLoaded
    public let hints: [VoteKey: VoteHint] = [:]
    public let windowNotClosed: WindowNotClosed? = nil
    public var entry: VotesEntry { VotesEntry() }

    public init() {}

    private func unsupported() -> VaultFailure { VaultFailure(.notSupported) }

    public func closeWindowNow() async throws {}
    public func refresh() async throws { throw unsupported() }
    public func refreshQuietly() {}
    public func get(_ key: VoteKey) async throws -> VoteDetail { throw unsupported() }
    public func cast(_ key: VoteKey, choiceID: String, password: String?) async throws -> BallotState { throw unsupported() }
    public func windowOpen() -> Bool { false }
    public func check(_ key: VoteKey) async throws { throw unsupported() }
    public func confirm(_ key: VoteKey, mine: Bool) async throws -> BallotState { throw unsupported() }
    public func evidence(_ key: VoteKey) async throws -> String { throw unsupported() }
    public func release(_ key: VoteKey, pin: String) async throws { throw unsupported() }
    public func acknowledgeDropped(_ connectionIDs: [String]) {}
    public func titleOf(_ key: VoteKey) -> String? { nil }
}
