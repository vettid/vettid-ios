import Foundation
import VettIDCalls

// Mirrors vettid-android `MediaDiagnostics.from` (the statistics reading of `MediaDiagnostics.kt`): the stack's statistics
// report as a ``MediaDiagnostics``. Types only: no address, port or identifier is kept, shown or logged.

/// One value of one statistics entry.
enum StatValue: Equatable, Sendable {
    case text(String)
    case number(Double)
}

/// One entry of the stack's statistics report (`RTCStatistics`), detached from the stack for tests.
struct StatEntry: Equatable, Sendable {
    let id: String
    let type: String
    let members: [String: StatValue]

    func text(_ key: String) -> String {
        if case let .text(value)? = members[key] { return value }
        return ""
    }

    func number(_ key: String) -> Double? {
        if case let .number(value)? = members[key] { return value }
        return nil
    }
}

enum MediaStatistics {
    /// The levels are the stack's `audioLevel` (0 silence, 1 full scale). The cryptor states are not in the statistics:
    /// the engine fills them in.
    static func diagnostics(from entries: [StatEntry]) -> MediaDiagnostics {
        var byId: [String: StatEntry] = [:]
        for entry in entries { byId[entry.id] = entry }
        func audio(_ type: String) -> StatEntry? { entries.first { $0.type == type && $0.text("kind") == "audio" } }
        let source = audio("media-source")
        let inbound = audio("inbound-rtp")
        let outbound = audio("outbound-rtp")
        let transport = entries.first { $0.type == "transport" && !$0.text("selectedCandidatePairId").isEmpty }
            ?? entries.first { $0.type == "transport" }
        let pair = transport.flatMap { byId[$0.text("selectedCandidatePairId")] }

        func candidate(_ key: String) -> CandidateInfo? {
            guard let found = pair.flatMap({ byId[$0.text(key)] }) else { return nil }
            return CandidateInfo(type: found.text("candidateType"), protocol: found.text("protocol"), network: found.text("networkType"))
        }
        func codec(_ entry: StatEntry?) -> String { entry.flatMap { byId[$0.text("codecId")] }?.text("mimeType") ?? "" }
        return MediaDiagnostics(
            micLevel: source?.number("audioLevel") ?? 0,
            remoteLevel: inbound?.number("audioLevel") ?? 0,
            packetsSent: Int64(outbound?.number("packetsSent") ?? 0),
            packetsReceived: Int64(inbound?.number("packetsReceived") ?? 0),
            inboundAudioStreams: entries.filter { $0.type == "inbound-rtp" && $0.text("kind") == "audio" }.count,
            sendCodec: codec(outbound),
            receiveCodec: codec(inbound),
            local: candidate("localCandidateId"),
            remote: candidate("remoteCandidateId"),
            roundTripMs: pair?.number("currentRoundTripTime").map { $0 * 1000 }
        )
    }
}
