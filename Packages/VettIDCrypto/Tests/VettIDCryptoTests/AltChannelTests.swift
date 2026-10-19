import Foundation
import Testing
@testable import VettIDCrypto

// The vector test checks every value of the file in one place, as vettid-android does.
// swiftlint:disable function_body_length

/// The §16 alternate-channel vector (`altchan.json`): the ETK descriptor and its user_data, the device-attestation
/// challenges, the unlock signing string (with release R's unlock secret) and signature, and the sealed unlock request
/// from both sides. Mirrors the altchan part of vettid-android `VectorsTest`, `DeviceAssertionTest` and the descriptor
/// part of `CapabilitiesTest`.
struct AltChannelTests {
    private let keys: VectorDoc

    init() throws { keys = try VectorDoc.load("keys.json") }

    @Test func altchan() throws {
        let d = try VectorDoc.load("altchan.json")
        let etk = try KemPrivateKey.fromSeed(try keys.sub("etk").hex("kem_seed_hex"))
        let deviceIk = try Ed25519PrivateKey.fromSeed(try keys.sub("initiator").hex("ik_seed_hex"))

        let desc = Array(try d.str("descriptor").utf8)
        #expect(AltChannel.etkUserData(desc) == (try d.hex("descriptor_user_data_hex")), "descriptor user_data")
        let parsed = try Descriptor.parse(desc)
        #expect(parsed.etk == etk.publicKey)
        #expect(parsed.bytes == desc)
        let remarshalled = Descriptor.marshal(
            instanceID: parsed.instanceID, etk: parsed.etk, release: parsed.release, notAfter: parsed.notAfter
        )
        #expect(remarshalled == desc)
        for k in ["devatt_enroll", "devatt_unlock"] {
            let c = try d.sub(k)
            let input = "vettid/vms/2/devatt" + (try c.str("request_id")) + (try c.str("vault_id")) + (try c.str("ts"))
            let want = Bytes.sha256(Array(input.utf8))
            #expect(want == (try c.hex("challenge_hex")), "\(k)")
            #expect(try AltChannel.devattChallenge(requestID: c.str("request_id"), vaultID: c.str("vault_id"), ts: c.str("ts")) == want)
        }

        let f = try d.sub("unlock_fields")
        #expect(try Kid.parseHex(try f.str("etk_kid_hex")) == etk.publicKey.kid)
        let rel = try VectorDoc.load("release.json")
        // The release approval (§11.10.3) byte for byte as vettid-vault's vector, and its SHA-256 (iOS's clientDataHash).
        let a = try rel.sub("approval")
        let approvalString = try AltChannel.approvalSigningString(
            vaultID: try a.str("vault_id"), requestID: try a.str("request_id"), fromPcr0: try a.str("from_pcr0_hex"),
            toPcr0: try a.str("to_pcr0_hex"), toRelease: try a.num("to_release"), serial: try a.num("manifest_serial")
        )
        #expect(approvalString == (try a.str("signing_string")))
        #expect(Bytes.sha256(Array(approvalString.utf8)) == (try a.hex("signing_string_sha256_hex")))
        #expect(Bytes.sha256(Array(try rel.str("manifest").utf8)) == (try f.hex("manifest_sha256_hex")), "unlock manifest hash")
        let inner = try Inner.parse(Array(try d.str("unlock_inner").utf8), .sealed)
        let body = try StrictJson.parseObject(inner.body)
        // Release R (0.33.0 §11.14): the request carries the phone's unlock secret, and the signing string ends with its hash.
        let unlockSecret = try body.base64("unlock_secret", AltChannel.unlockSecretSize)
        let fields = AltChannel.UnlockFields(
            userGuid: try f.str("user_guid"),
            vaultID: try f.str("vault_id"),
            requestID: try f.str("request_id"),
            ts: try f.str("ts"),
            etkKid: try Kid.parseHex(try f.str("etk_kid_hex")),
            minStateSeq: try f.num("min_state_seq"),
            minHeaderSeq: try f.num("min_header_seq"),
            pin: try f.str("pin"),
            token: try f.str("token"),
            manifestSHA256: try f.str("manifest_sha256_hex"),
            toPcr0: try f.str("to_pcr0_hex"),
            unlockSecret: unlockSecret
        )
        let signing = try AltChannel.unlockSigningString(fields)
        #expect(signing == (try d.str("unlock_signing_string")))
        #expect(signing.split(separator: "\n", omittingEmptySubsequences: false).count == 13)
        let sig = try d.b64("unlock_sig_b64")
        #expect(Ed25519.verifyRaw(deviceIk.publicKey, Array(signing.utf8), sig))
        #expect(try deviceIk.signRaw(Array(signing.utf8)) == sig, "unlock sig (deterministic)")

        let raw = try d.b64("unlock_envelope_b64")
        #expect(raw.count == 13_444)
        #expect(raw.count == AltChannel.requestEnvelopeSize)
        #expect(try d.num("unlock_envelope_len") == 13_444)
        let (pt, _) = try Envelope.openSealed(try Envelope.parse(raw), key: etk)
        #expect(try Padding.unpadFixed(pt, 12_288) == Array(try d.str("unlock_inner").utf8))
        #expect(try DeviceAssertion.parse(try body.obj("device_assertion")) == (try DeviceAssertion.androidSignature(rep(0x2A, 72))))
        #expect(try body.string("manifest_sha256") == (try rel.str("manifest_sha256_hex")))
        #expect(try body.uint("manifest_serial", min: 1, max: 100) == 7)
        #expect(!body.has("manifest"))

        // Sender side: the request body, its inner and the sealed envelope, byte for byte.
        let req = UnlockRequest(
            userGuid: fields.userGuid,
            vaultID: fields.vaultID,
            requestID: fields.requestID,
            deviceIk: deviceIk.publicKey,
            pin: fields.pin,
            minStateSeq: fields.minStateSeq,
            minHeaderSeq: fields.minHeaderSeq,
            token: fields.token,
            assertion: try DeviceAssertion.androidSignature(rep(0x2A, 72)),
            manifestSHA256: fields.manifestSHA256,
            manifestSerial: 7,
            sig: sig,
            unlockSecret: unlockSecret
        )
        #expect(try req.marshal() == Array(try StrictJson.parseObject(try d.str("unlock_inner")).obj("body").raw.utf8))
        let ts = try Timestamps.parseMillis(fields.ts)
        let built = try deterministic(try d.hex("unlock_encapsulation_randomness_hex")) {
            try AltChannel.sealRequest(
                etk: etk.publicKey, type: AltChannel.typeUnlock, requestID: fields.requestID, ts: ts, body: req.marshal()
            )
        }
        #expect(built == raw, "unlock envelope")
        // Once sent, the request's copy of the secret is gone.
        req.wipe()
        #expect(String(bytes: try req.marshal(), encoding: .utf8)?.contains("unlock_secret") == false)
    }

    @Test func signingStringRules() throws {
        let base = AltChannel.UnlockFields(
            userGuid: "u", vaultID: "v", requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T21", ts: "2026-10-01T12:00:00.000Z",
            etkKid: Kid.anonymous, minStateSeq: 1, minHeaderSeq: 2, pin: "123456", token: "t",
            manifestSHA256: String(repeating: "ab", count: 32)
        )
        #expect(try AltChannel.unlockSigningString(base).split(separator: "\n", omittingEmptySubsequences: false).count == 12)
        let cancel = AltChannel.UnlockFields(
            userGuid: "u", vaultID: "v", requestID: base.requestID, ts: base.ts, etkKid: base.etkKid, minStateSeq: 1, minHeaderSeq: 2,
            pin: "123456", token: "t", manifestSHA256: base.manifestSHA256, cancelRecovery: true
        )
        #expect(try AltChannel.unlockSigningString(cancel).hasSuffix("\n\ncancel_recovery"))
        let badPin = AltChannel.UnlockFields(
            userGuid: "u", vaultID: "v", requestID: base.requestID, ts: base.ts, etkKid: base.etkKid, minStateSeq: 1, minHeaderSeq: 2,
            pin: "12\n3456", token: "t", manifestSHA256: base.manifestSHA256
        )
        expectCrypto(.format) { _ = try AltChannel.unlockSigningString(badPin) }
        let shortSecret = AltChannel.UnlockFields(
            userGuid: "u", vaultID: "v", requestID: base.requestID, ts: base.ts, etkKid: base.etkKid, minStateSeq: 1, minHeaderSeq: 2,
            pin: "123456", token: "t", manifestSHA256: base.manifestSHA256, unlockSecret: rep(1, 31)
        )
        expectCrypto(.format) { _ = try AltChannel.unlockSigningString(shortSecret) }
        // The release-approval string (§11.10.3): seven lines.
        let pcrA = String(repeating: "a1", count: 48)
        let pcrB = String(repeating: "b2", count: 48)
        let approval = try AltChannel.approvalSigningString(
            vaultID: "v", requestID: base.requestID, fromPcr0: pcrA, toPcr0: pcrB, toRelease: 5, serial: 9
        )
        #expect(approval == ["vettid/vms/2/release-approval", "v", base.requestID, pcrA, pcrB, "5", "9"].joined(separator: "\n"))
        expectCrypto(.format) {
            _ = try AltChannel.approvalSigningString(
                vaultID: "v", requestID: base.requestID, fromPcr0: pcrA, toPcr0: pcrB, toRelease: 0, serial: 9
            )
        }
        #expect(AltChannel.isValidPin("123456"))
        #expect(!AltChannel.isValidPin("12345"))
        #expect(!AltChannel.isValidPin("12345a"))
        expectCrypto(.format) { _ = try AltChannel.devattChallenge(requestID: "not-a-ulid", vaultID: "", ts: base.ts) }
    }

    @Test func deviceAssertionForms() throws {
        let sig = (0..<71).map { UInt8($0 + 1) }
        let leaf = rep(0x11, 600)
        let root = rep(0x22, 500)
        // Without a chain the wire form is as before.
        let a = try DeviceAssertion.androidSignature(sig)
        #expect(a.marshal() == #"{"platform":"android","sig":"\#(Base64s.encodeStd(sig))"}"#)
        // The chain follows the signature, leaf first.
        let withChain = try DeviceAssertion.androidSignature(sig, chain: [leaf, root])
        let b64 = [sig, leaf, root].map(Base64s.encodeStd)
        #expect(withChain.marshal() == #"{"platform":"android","sig":"\#(b64[0])","chain":["\#(b64[1])","\#(b64[2])"]}"#)
        #expect(try DeviceAssertion.parse(try StrictJson.parseObject(withChain.marshal())) == withChain)
        #expect(withChain.withoutChain() == a)
        // A chain is one to ten certificates.
        expectCrypto(.format) { _ = try DeviceAssertion.androidSignature(sig, chain: []) }
        expectCrypto(.format) { _ = try DeviceAssertion.androidSignature(sig, chain: Array(repeating: leaf, count: 11)) }
        expectCrypto(.format) { _ = try DeviceAssertion.androidSignature(sig, chain: [leaf, []]) }
        let emptyChain = #"{"platform":"android","sig":"\#(b64[0])","chain":[]}"#
        expectCrypto(.format) { _ = try DeviceAssertion.parse(try StrictJson.parseObject(emptyChain)) }
        // The iPhone's form (§11.7): an App Attest assertion.
        let ios = try DeviceAssertion.iosAssertion(rep(0xA5, 120))
        #expect(ios.marshal() == #"{"platform":"ios","assertion":"\#(Base64s.encodeStd(rep(0xA5, 120)))"}"#)
        #expect(try DeviceAssertion.parse(try StrictJson.parseObject(ios.marshal())) == ios)
        #expect(ios.withoutChain() == ios)
        expectCrypto(.format) { _ = try DeviceAssertion.iosAssertion([]) }
        expectCrypto(.format) { _ = try DeviceAssertion.parse(try StrictJson.parseObject(#"{"platform":"web","sig":"AA=="}"#)) }
    }

    @Test func descriptorCapabilities() throws {
        let pcr = String(repeating: "a3", count: 48)
        let notAfter = try Timestamps.parseSeconds("2026-10-17T12:00:00Z")
        let etk = try KemPrivateKey.generate().publicKey
        func marshal(_ instance: String = "inst-a", release: String? = nil, capabilities: [String]? = nil) -> [UInt8] {
            Descriptor.marshal(instanceID: instance, etk: etk, release: release ?? pcr, notAfter: notAfter, capabilities: capabilities)
        }
        let before = try Descriptor.parse(marshal())
        #expect(before.capabilities.isEmpty)
        let rBytes = marshal(capabilities: ["recovery_offered", "recovery_r"])
        let r = try Descriptor.parse(rBytes)
        #expect(r.capabilities == ["recovery_offered", "recovery_r"])
        // The descriptor bytes are the attested ones: the list is part of them.
        #expect(r.bytes == rBytes)
        let unsorted = marshal(capabilities: ["recovery_r", "attachments"])
        expectCrypto(.format) { _ = try Descriptor.parse(unsorted) }
        // A staging release with the time scale (VAULT-MESSAGING 0.43.0, STAGING-TIME-SCALE §5.2) writes `time_scale` after
        // the capabilities: a member this app does not read yet, which it ignores (§5.3).
        let scaled = try #require(String(bytes: rBytes, encoding: .utf8)).dropLast() + #","time_scale":24}"#
        #expect(try Descriptor.parse(Array(scaled.utf8)).capabilities == ["recovery_offered", "recovery_r"])
        // A debug (all-zero) PCR, a kid that is not the ETK's, a bad instance id: refused.
        expectCrypto(.format) {
            _ = try Descriptor.parse(marshal(release: String(repeating: "0", count: 96)))
        }
        expectCrypto(.format) { _ = try Descriptor.parse(marshal("inst a")) }
        let otherKid = try #require(String(bytes: marshal(), encoding: .utf8))
            .replacingOccurrences(of: etk.kid.description, with: "0000000000000000")
        expectCrypto(.format) { _ = try Descriptor.parse(Array(otherKid.utf8)) }
    }

    @Test func transferBundleCapabilities() throws {
        let ik = Ed25519PrivateKey.generate()
        let relaySigner = Ed25519PrivateKey.generate()
        let vault = Principal(
            ik: ik.publicKey,
            kem: try KemPrivateKey.generate().publicKey,
            relay: RelayAddr(url: "https://relay.vettid.org", mailbox: Mailbox.id(relaySigner.publicKey), pk: relaySigner.publicKey)
        )
        let exp = try Timestamps.parseSeconds("2026-10-01T12:10:00Z")
        let now = try Timestamps.parseSeconds("2026-10-01T12:00:00Z")
        let token = "v4.public." + "b3Blbg"
        let id = "01JB2Z6V9K3M4N5P6Q7R8S9T0V"
        let app = InviteBundle(kind: .app, inviteID: id, remote: false, vault: vault, token: token, exp: exp, capabilities: ["recovery_r"])
        let sealed = try InviteBundle.seal(try app.marshal())
        let qr = InviteQr(
            kind: .app, relay: "https://relay.vettid.org", claimID: "abcdefghijklmnopqrstuvwxyz", hash: sealed.hash, key: sealed.key,
            exp: UInt64(exp.timeIntervalSince1970)
        )
        #expect(try InviteBundle.open(sealed.blob, qr: qr, now: now).capabilities == ["recovery_r"])
        // A transfer bundle from a release before R: none.
        let plain = InviteBundle(kind: .app, inviteID: id, remote: false, vault: vault, token: token, exp: exp)
        #expect(try InviteBundle.parse(try plain.marshal()).capabilities == nil)
        // Another kind with the member: refused, as a malformed bundle.
        let connectionBundle = InviteBundle(kind: .connection, inviteID: id, remote: false, vault: vault, token: token, exp: exp)
        let connection = try #require(String(bytes: try connectionBundle.marshal(), encoding: .utf8))
            .replacingOccurrences(of: "\"exp\":", with: "\"capabilities\":[\"recovery_r\"],\"exp\":")
        expectCrypto(.format) { _ = try InviteBundle.parse(Array(connection.utf8)) }
        expectCrypto(.format) {
            _ = try InviteBundle(
                kind: .desktop, inviteID: id, remote: false, vault: vault, token: token, exp: exp, capabilities: []
            ).marshal()
        }
    }
}
// swiftlint:enable function_body_length
