import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

/// The credential key of every credential the device keeps from an answer (VAULT-MESSAGING 0.83.8 §10.8; ANDROID-PLAN
/// 0.1.119 §4 "Owner check and status"): what Vault status's Credential key row shows. Mirrors vettid-android's
/// `VaultDeviceTest` key-emission tests.
@Suite struct CredentialKeyChangesTests {
    let ops = CredentialOpsTests()

    /// What [stream] gave up to now: a marker is emitted after the operation and read up to.
    func seen(_ d: VaultDevice, _ stream: AsyncStream<CredentialKeySeen>) async -> [String?] {
        d.noteCredentialKey("end-of-test")
        var out: [String?] = []
        for await s in stream {
            if s.key == "end-of-test" { break }
            out.append(s.key)
        }
        return out
    }

    func create(answer: String) async throws -> (VaultDevice, [String?]) {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let stream = d.credentialKeyChanges()
        let create = Task { try await api.credentialCreate(password: "a long password here", pin: "123456") }
        try await ops.answer(v, d, "credential.utk.get", try ops.pool(3).body)
        try await ops.answer(v, d, "credential.create", answer)
        try await ops.answer(v, d, "credential.ack")
        try await create.value
        return (d, await seen(d, stream))
    }

    /// A credential kept with a key says it, once the blob is stored.
    @Test func aKeyReplacingAnswerWithAKeyEmitsIt() async throws {
        let (d, keys) = try await create(answer: #"{"credential":"AQID","version":1,"key":"a2V5LW9uZQ=="}"#)
        #expect(keys == ["a2V5LW9uZQ=="] && d.credentialVersion == 1)
    }

    /// One that names none replaced the credential all the same: "key unknown" (nil), never silence.
    @Test func aKeyReplacingAnswerWithoutAKeySaysTheKeyIsUnknown() async throws {
        let (_, keys) = try await create(answer: #"{"credential":"AQID","version":1}"#)
        #expect(keys == [nil])
    }

    /// An empty key is no key.
    @Test func anEmptyKeyIsNoKey() async throws {
        let (_, keys) = try await create(answer: #"{"credential":"AQID","version":1,"key":""}"#)
        #expect(keys == [nil])
    }

    /// A top-up carries no credential: nothing to say.
    @Test func anAnswerWithoutACredentialSaysNothing() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let stream = d.credentialKeyChanges()
        let top = Task { try await api.topUpUTKs() }
        try await ops.answer(v, d, "credential.utk.get", try ops.pool(2).body)
        try await top.value
        #expect(await seen(d, stream).isEmpty)
    }

    /// A credential kept by an operation that keeps the key (`credential.get`), naming none: nothing to say, so no
    /// second `credential.version` for an open Vault status.
    @Test func aKeyKeepingAnswerWithoutAKeySaysNothing() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let stream = d.credentialKeyChanges()
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":2}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
        #expect(await seen(d, stream).isEmpty && d.credentialVersion == 2)
    }

    /// The operations whose answer replaces the key.
    @Test func theKeyReplacingOperations() {
        #expect(CredentialOps.keyReplacing == ["credential.create", "credential.rotate", "credential.reset"])
    }

    /// Never printed.
    @Test func aSeenKeyPrintsItsTypeOnly() {
        #expect("\(CredentialKeySeen(key: "a2V5LW9uZQ=="))" == "CredentialKeySeen")
    }
}
