import CryptoKit
import Foundation
import Testing
import VettIDAltChanTesting
import VettIDCrypto
import VettIDRelay
import VettIDTesting

/// The dev stack's helpers (VettIDAltChanTesting `DevStack`) against a fake server answering as vettid-vault
/// `cmd/devstack`'s control port and member API stand-in do.
@Suite struct DevStackTests {
    let server = FakeHTTPServer()

    var stack: DevStack {
        DevStack(api: server.baseURL, relayTransport: server.baseURL, control: server.baseURL, session: server.session)
    }

    @Test func theDefaultsAreTheStacksPorts() {
        let s = DevStack.fromEnvironment([:])
        #expect(s.apiBase == "http://127.0.0.1:18081" && s.relayTransport == "http://127.0.0.1:18080")
        #expect(s.control == "http://127.0.0.1:18082")
        #expect(s.relayURL == "https://relay.vettid.test")
        #expect(s.manifestURL == "http://127.0.0.1:18081/.well-known/vettid/pcr-manifest.json")
        let o = DevStack.fromEnvironment(["VETTID_DEVSTACK_API": "http://10.0.0.2:1", "VETTID_DEVSTACK_CTL": "http://10.0.0.2:3"])
        #expect(o.apiBase == "http://10.0.0.2:1" && o.control == "http://10.0.0.2:3" && o.relayTransport == "http://127.0.0.1:18080")
    }

    @Test func theRelaysOriginGoesToItsPort() async throws {
        server.enqueue(.json(200, "{}"))
        let url = try #require(URL(string: "https://relay.vettid.test/v1/mailboxes?x=1"))
        _ = try await stack.transport.send(policy: .idempotent, maxBody: 1024) { URLRequest(url: url) }
        #expect(server.requests.map(\.path) == ["/v1/mailboxes"])
        #expect(server.requests.first?.url.host == URL(string: server.baseURL)?.host)
        #expect(server.requests.first?.query == "x=1")
    }

    @Test func trustComesFromTheControlPort() async throws {
        let spki = Array(P256.Signing.PrivateKey().publicKey.derRepresentation)
        let root: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x01]
        let keys = JsonBuilder.array([JsonBuilder.quote(Base64s.encodeStd(spki))])
        let trust = JsonBuilder().base64("nitro_root", root).raw("manifest_keys", keys)
            .string("relay_url", "https://relay.vettid.test").raw("device_policy", "null").build()
        server.enqueue(.json(200, trust))
        let t = try await stack.trust()
        #expect(t.nitroRoots == [root])
        #expect(t.manifestKeys.count == 1)
        #expect(server.requests.map(\.path) == ["/dev/trust"])
    }

    @Test func aSetupCodeIsIssuedForTheMember() async throws {
        server.enqueue(.json(201, #"{"secret":"S3CR3T","expires_at":"2026-10-18T00:00:00Z"}"#), .json(404, #"{"error":"not_found"}"#))
        #expect(try await stack.issueSetupCode(guid: "ios-1") == "S3CR3T")
        let r = try #require(server.requests.first)
        #expect(r.method == "POST" && r.path == "/api/vault/enroll-code" && r.header("Authorization") == "Bearer ios-1")
        await #expect(throws: DevStackError.self) { _ = try await stack.issueSetupCode(guid: "ios-2") }
    }

    @Test func thePeerIsDrivenThroughTheControlPort() async throws {
        server.enqueue(
            .json(200, #"{"status":"ok","body":{"connection_id":"c1"}}"#),
            .json(200, #"{"status":"error","error":{"code":"bad"}}"#),
            .json(200, #"{"type":"message.new","body":{"text":"hi","direction":"in"}}"#)
        )
        let accepted = try await stack.peerRequest("connection.invite.accept", body: #"{"link":"vettid://x"}"#)
        #expect(try accepted.string("connection_id") == "c1")
        await #expect(throws: DevStackError.self) { try await stack.peerRequest("message.send") }
        let ev = try await stack.peerEvent("message.new", match: ["text": "hi"], timeoutSeconds: 5)
        #expect(try ev.string("direction") == "in")
        let bodies = server.requests.map { String(bytes: $0.body, encoding: .utf8) ?? "" }
        #expect(bodies == [
            #"{"type":"connection.invite.accept","body":{"link":"vettid://x"}}"#,
            #"{"type":"message.send","body":{}}"#,
            #"{"type":"message.new","match":{"text":"hi"},"timeout_s":5}"#,
        ])
        #expect(server.requests.map(\.path) == ["/dev/peer/request", "/dev/peer/request", "/dev/peer/event"])
    }

    @Test func activeConnectionsAndNewOnes() async throws {
        let list = #"{"status":"ok","body":{"connections":[{"id":"a","state":"active"},{"id":"b","state":"pending"}]}}"#
        let more = #"{"status":"ok","body":{"connections":[{"id":"a","state":"active"},{"id":"c","state":"active"}]}}"#
        server.enqueue(.json(200, list), .json(200, more))
        #expect(try await stack.peerActiveConnections() == ["a"])
        #expect(try await stack.peerAwaitNewConnection(known: ["a"], timeoutSeconds: 5) == "c")
    }
}
