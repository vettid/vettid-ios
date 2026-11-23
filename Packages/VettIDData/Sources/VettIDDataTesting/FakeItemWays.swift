import Foundation
import Observation
import VettIDData

/// TEST ONLY. How an agent may use its items (ANDROID-PLAN 0.1.137 AA7) for view-model tests and the screen catalog: [current] is
/// the `item_ways` JSON a read answers (nil: no rule of the agent includes the item); each save is recorded in [saves] and
/// answered from [answers] (else `Saved` with what was sent), each turn-off in [offs]. [readGates] hold the answers of the next
/// reads, [saveGate] the answer of a save. [fireEvent(_:)] is a `sync.event` for the pages. Mirrors the fake of vettid-android
/// `ItemWaysViewModelTest`.
@MainActor
@Observable
public final class FakeItemWays: ItemWaysRepository {
    /// A save: the settings sent, the password (nil: none) and whether it was the resend after `credential_locked`.
    public struct Sent: Equatable, Sendable {
        public let next: ItemWays
        public let password: String?
        public let resent: Bool
    }

    public private(set) var items: [String: [ItemWaysRead]] = [:]
    public var listed = true
    public private(set) var event: ItemWaysEvent?
    public var windowNotClosed: WindowNotClosed?
    @ObservationIgnored public var current: String? = #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]}"#
    @ObservationIgnored public var saves: [Sent] = []
    @ObservationIgnored public var answers: [ItemWaysSave] = []
    @ObservationIgnored public var offs: [String] = []
    @ObservationIgnored public var reads = 0
    /// What `list` answers (agent id to the `item_ways` JSON of each item), and how many lists were read.
    @ObservationIgnored public var listAnswer: [String] = []
    @ObservationIgnored public var lists: [String] = []
    /// The next read or list fails with this (once).
    @ObservationIgnored public var failRead: VaultFailure?
    @ObservationIgnored public var failList: VaultFailure?
    /// Held until completed: a read's answer waits for it (one answer per gate, in order).
    @ObservationIgnored public var readGates: [TestDeferred<String?>] = []
    @ObservationIgnored public var saveGate: TestDeferred<Void>?
    /// The vault's `Saved` carries the next version, as a real save does (else the version sent).
    @ObservationIgnored public var bump = false
    @ObservationIgnored public var closed = 0
    private var eventSeq = 0

    public init() {}

    /// An event for the pages (a `leash.item.changed` or a rule event).
    public func fireEvent(_ kind: ItemWaysEvent.Kind) {
        eventSeq += 1
        event = ItemWaysEvent(seq: eventSeq, kind: kind)
    }

    public func list(_ agentID: String) async throws -> [ItemWaysRead] {
        lists.append(agentID)
        if let f = failList {
            failList = nil
            throw f
        }
        let r = listAnswer.compactMap { ItemWaysRules.one(Array($0.utf8)) }
        items[agentID] = r
        return r
    }

    public func read(_ agentID: String, _ itemID: String) async throws -> ItemWaysRead? {
        reads += 1
        if let f = failRead {
            failRead = nil
            throw f
        }
        var answer = current
        if !readGates.isEmpty { answer = try await readGates.removeFirst().value() }
        return answer.flatMap { ItemWaysRules.one(Array($0.utf8)) }
    }

    public func save(_ cur: ItemWaysRead, _ next: ItemWays, password: String?, resent: Bool) async throws -> ItemWaysSave {
        saves.append(Sent(next: next, password: password, resent: resent))
        if let g = saveGate { try await g.value() }
        var saved = next
        if bump { saved.version = (next.version ?? 0) + 1 }
        if !answers.isEmpty { return answers.removeFirst() }
        return .saved(ItemWaysRules.one(saved.setBody())!)
    }

    public func turnOff(_ cur: ItemWaysRead, _ way: String) async throws -> ItemWaysSave {
        offs.append(way)
        if !answers.isEmpty { return answers.removeFirst() }
        return .saved(cur)
    }

    public func closeWindowNow() async throws {
        closed += 1
        windowNotClosed = nil
    }
}
