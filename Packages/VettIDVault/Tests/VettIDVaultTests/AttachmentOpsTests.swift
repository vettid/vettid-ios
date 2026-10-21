import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The photo calls (VAULT-MESSAGING §10.5.1) against the fake vault and relay: the probe, the send with its inner id, the
/// two parts of `message.attachment.get`, the discard, and the blobs through the relay.
@Suite struct AttachmentOpsTests {
    let ops = CredentialOpsTests()

    /// "Compatibility": `bad_request` is release A, `unsupported_type` an older vault, anything else unknown.
    @Test func theProbeReadsReleaseAFromTheAnswer() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        for (code, expected) in [("bad_request", true as Bool?), ("unsupported_type", false), ("busy", nil)] {
            let probe = Task { try await api.attachmentsSupported() }
            let req = try await ops.answer(v, d, "message.attachment.get", code: code, errorBody: "{}")
            #expect(String(bytes: req.body, encoding: .utf8) == "{}")
            #expect(try await probe.value == expected)
        }
    }

    /// Step 2: the device send view without `name`, the caption only when there is one, under the given inner id.
    @Test func aPhotoIsSentWithItsReferenceUnderTheGivenInnerId() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let att = AttachmentSend(blobID: "B1", key: [UInt8](repeating: 1, count: 32), sha256: [UInt8](repeating: 2, count: 32), size: 812_345, mime: "image/jpeg", width: 2_560, height: 1_920, thumb: [0xFF, 0xD8, 0xFF])
        let id = d.newRequestID()
        let send = Task { try await api.messageSendPhoto("c1", text: "", attachment: att, requestID: id) }
        let req = try await ops.answer(v, d, "message.send", #"{"message_id":"M1","sent_at":"2026-10-20T12:00:00.000Z","att_id":"A1"}"#)
        #expect(req.id == id)
        let key = Base64s.encodeStd([UInt8](repeating: 1, count: 32)), sha = Base64s.encodeStd([UInt8](repeating: 2, count: 32))
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"connection_id":"c1","attachment":{"blob":{"id":"B1","key":"\#(key)","sha256":"\#(sha)","size":812345,"mime":"image/jpeg"},"kind":"photo","width":2560,"height":1920,"thumb":"/9j/"}}"#)
        #expect(try await send.value == SentAttachment(messageID: "M1", sentAt: "2026-10-20T12:00:00.000Z", attID: "A1"))
        #expect(!String(describing: att).contains(key) && !String(describing: att).contains("B1"))

        let captioned = Task { try await api.messageSendPhoto("c1", text: "At the lake", attachment: att, requestID: d.newRequestID()) }
        let req2 = try await ops.answer(v, d, "message.send", #"{"message_id":"M2","sent_at":"2026-10-20T12:00:00.000Z"}"#)
        #expect(String(bytes: req2.body, encoding: .utf8)?.hasPrefix(#"{"connection_id":"c1","text":"At the lake","attachment":"#) == true)
        await #expect(throws: VaultStateError.self) { _ = try await captioned.value }
    }

    @Test func theThumbAndTheContentAreAskedByPart() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let thumb = Task { try await api.attachmentThumb("c1", messageID: "M1") }
        var req = try await ops.answer(v, d, "message.attachment.get", #"{"thumb":"/9j/4A=="}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"connection_id":"c1","message_id":"M1","part":"thumb"}"#)
        #expect(try await thumb.value == [0xFF, 0xD8, 0xFF, 0xE0])

        let content = Task { try await api.attachmentContent("c1", messageID: "M1") }
        req = try await ops.answer(v, d, "message.attachment.get", #"{"blob":{"id":"B9","key":"a2V5","sha256":"c2hh","size":10,"mime":"image/png","name":"../x.png"},"expires_at":"2026-10-28T00:00:00Z"}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"connection_id":"c1","message_id":"M1","part":"content"}"#)
        let got = try await content.value
        #expect(got == FetchedAttachment(blob: BlobRef(id: "B9", key: "a2V5", sha256: "c2hh", size: 10, mime: "image/png", name: "../x.png"), expiresAt: "2026-10-28T00:00:00Z"))
        #expect(!String(describing: got.blob).contains("a2V5"))

        let broken = Task { try await api.attachmentContent("c1", messageID: "M1") }
        try await ops.answer(v, d, "message.attachment.get", #"{"blob":{"id":"B9"}}"#)
        await #expect(throws: VaultStateError.self) { _ = try await broken.value }
    }

    @Test func theDiscardNamesTheBlob() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let discard = Task { try await api.messageAttachmentDiscard("B1") }
        let req = try await ops.answer(v, d, "message.attachment.discard")
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"blob_id":"B1"}"#)
        try await discard.value
    }

    /// The upload goes to the vault's mailbox; a blob in this device's mailbox is fetched and deleted; a full mailbox is
    /// the relay's `quota_exceeded`.
    @Test func blobsGoThroughTheRelay() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let id = try await api.uploadBlob([1, 2, 3])
        #expect(ops.base.relay.blob(id) == [1, 2, 3])
        #expect(ops.base.relay.blobs[id]?.mailbox == v.mailbox)
        ops.base.relay.putBlob("DOWN1", [9, 8, 7], mailbox: "device")
        #expect(try await api.fetchBlob("DOWN1") == [9, 8, 7])
        try await api.deleteBlob("DOWN1")
        #expect(ops.base.relay.blob("DOWN1") == nil)
        ops.base.relay.refuseBlobs = RelayError.quotaExceeded
        do {
            _ = try await api.uploadBlob([4])
            Issue.record("expected a refusal")
        } catch let e as RelayError {
            #expect(e.code == RelayError.quotaExceeded)
        }
    }

    /// The device view reads its members; unknown ones are ignored, a view without `att_id` is none.
    @Test func theDeviceViewIsRead() throws {
        let m = try #require(Message.of(try StrictJson.parseObject(#"{"connection_id":"c1","message_id":"m1","direction":"in","text":"","sent_at":"2026-10-20T12:00:00.000Z","attachment":{"att_id":"A1","kind":"photo","size":10,"width":320,"height":240,"name":"x.jpg","state":"failed","reason":"withdrawn:deleted","thumb":"/9j/","future":1}}"#)))
        let a = try #require(m.attachmentView)
        #expect(a.attID == "A1" && a.size == 10 && a.width == 320 && a.height == 240 && a.name == "x.jpg")
        #expect(a.state == "failed" && a.reason == "withdrawn:deleted" && a.thumb == "/9j/" && a.mime == nil)
        #expect(AttachmentView.of(try StrictJson.parseObject(#"{"kind":"photo"}"#)) == nil)
    }
}

// swiftlint:enable line_length
