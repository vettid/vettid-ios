import Foundation
import Observation
import VettIDData
import VettIDMedia

/// TEST ONLY. Photo attachments for view-model tests, like ``FakeMessages``: records the calls, prepares by wrapping the
/// source bytes, and fails a call once when ``fail`` names it. Mirrors vettid-android `FakeAttachments`.
@MainActor
@Observable
public final class FakeAttachments: AttachmentsRepository {
    public var calls: [String] = []
    /// A failure the next call of that name throws (once).
    public var fail: [String: any Error] = [:]
    public var available = true
    public var cleared = 0
    public var seq = 0
    /// Every photo ``prepare(_:)`` made, to check that a cancel wiped them.
    public var prepared: [PreparedPhoto] = []
    /// When set, ``send(_:)`` waits for it (a request on its way).
    public var sendGate: TestDeferred<Void>?
    /// When set, ``thumbnail(_:messageID:)`` and ``photo(_:messageID:)`` wait for it (a fetch on its way).
    public var fetchGate: TestDeferred<Void>?
    /// When set, ``prepare(_:)`` waits for it before preparing a source of that first byte.
    public var prepareGates: [UInt8: TestDeferred<Void>] = [:]
    /// The thumbnail and the photo this fake serves (a JPEG's first bytes).
    public var served: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]

    public init() {}

    private func call(_ name: String) throws {
        calls.append(name)
        if let f = fail.removeValue(forKey: name) { throw f }
    }

    public func probe() async { calls.append("probe") }

    /// Every source ``prepare(_:)`` was given, to check that the caller wiped it after.
    public var sources: [PhotoBytes] = []

    public func prepare(_ source: PhotoBytes) async throws -> PreparedPhoto {
        sources.append(source)
        let bytes = source.copy()
        if let first = bytes.first, let gate = prepareGates[first] { try await gate.value() }
        try call("prepare")
        if bytes.isEmpty { throw PhotoError(.unreadable) }
        let p = PreparedPhoto(jpeg: bytes, thumb: [1, 2, 3], width: 2_560, height: 1_920)
        prepared.append(p)
        return p
    }

    public func begin(_ connectionID: String, caption: String, photo: PreparedPhoto) -> PendingPhoto {
        calls.append("begin:\(caption)")
        seq += 1
        return PendingPhoto.testOnly(connectionID: connectionID, caption: caption, photo: photo, requestID: "REQ\(seq)")
    }

    @discardableResult
    public func send(_ p: PendingPhoto) async throws -> MessageInfo {
        calls.append("send:\(p.requestID)")
        if let gate = sendGate { try await gate.value() }
        if let f = fail.removeValue(forKey: "send") { throw f }
        return MessageInfo(connectionID: p.connectionID, messageID: "M\(p.requestID)", outgoing: true, text: p.caption, sentAt: Date())
    }

    public func cancel(_ p: PendingPhoto) async { calls.append("cancel:\(p.requestID)") }

    public func abandon(_ p: PendingPhoto) { calls.append("abandon:\(p.requestID)") }

    public func thumbnail(_ connectionID: String, messageID: String) async throws -> [UInt8] {
        try call("thumbnail")
        if let gate = fetchGate { try await gate.value() }
        return served
    }

    public func photo(_ connectionID: String, messageID: String) async throws -> FetchedPhoto {
        try call("photo")
        if let gate = fetchGate { try await gate.value() }
        return FetchedPhoto(bytes: served, type: .jpeg)
    }

    public func cachedThumbnail(_ connectionID: String, messageID: String) -> [UInt8]? { nil }

    public func clear() {
        calls.append("clear")
        cleared += 1
    }
}
