import CryptoKit
import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay

/// TEST ONLY. The local dev stack (vettid-vault `cmd/devstack`, `scripts/devstack-test.sh`) as tests reach it: on the
/// Mac, and from the simulator, which shares the Mac's `127.0.0.1`. The relay URL that tokens name is
/// `https://relay.vettid.test`; its requests go to the relay's plain-HTTP port (``transport``'s origin map). The
/// control port serves the stack's TEST-ONLY trust anchors and drives the `vaultctl` peer vault. Mirrors vettid-android
/// `DevStack` and `SetupCodes`.
public final class DevStack: CustomStringConvertible, Sendable {
    /// The marker the release check refuses in a Release or Staging app.
    public static let testOnlyMarker = "VETTID TEST ONLY: the local dev stack's helpers"
    public static let defaultAPI = "http://127.0.0.1:18081"
    public static let defaultRelayTransport = "http://127.0.0.1:18080"
    public static let defaultControl = "http://127.0.0.1:18082"
    /// The relay base URL tokens name (`aud`).
    public static let relayURL = "https://relay.vettid.test"
    static let pollInterval: TimeInterval = 1
    static let maxBody = 1 << 20

    public let apiBase: String
    public let relayTransport: String
    public let control: String
    /// Every request of the app's code: the relay's origin mapped to its port.
    public let transport: HTTPTransport

    public var description: String { Self.testOnlyMarker }
    public var relayURL: String { Self.relayURL }
    public var manifestURL: String { apiBase + MemberApiClient.manifestPath }

    /// [session]: tests of these helpers pass a fake server's.
    public init(
        api: String = defaultAPI, relayTransport: String = defaultRelayTransport, control: String = defaultControl,
        session: URLSession? = nil
    ) {
        apiBase = api
        self.relayTransport = relayTransport
        self.control = control
        let config = URLSessionConfiguration.ephemeral
        // The peer's requests and event waits take minutes (vettid-vault cmd/devstack: event waits up to 300 s).
        config.timeoutIntervalForRequest = 310
        transport = HTTPTransport(session: session ?? URLSession(configuration: config), originMap: [Self.relayURL: relayTransport])
    }

    /// The addresses from `VETTID_DEVSTACK_API`, `VETTID_DEVSTACK_RELAY` and `VETTID_DEVSTACK_CTL`, else the defaults.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> DevStack {
        DevStack(
            api: env["VETTID_DEVSTACK_API"] ?? defaultAPI,
            relayTransport: env["VETTID_DEVSTACK_RELAY"] ?? defaultRelayTransport,
            control: env["VETTID_DEVSTACK_CTL"] ?? defaultControl
        )
    }

    /// Whether the stack answers (tests skip without it).
    public func reachable() async -> Bool {
        guard let url = URL(string: control + "/dev/health") else { return false }
        var r = URLRequest(url: url)
        r.timeoutInterval = 3
        do {
            let (_, resp) = try await transport.session.data(for: transport.prepared(r))
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// The stack's TEST-ONLY trust (`GET /dev/trust`): its test Nitro root and test manifest keys.
    public func trust() async throws -> AltTrust {
        let (_, o) = try await call("GET", control + "/dev/trust", body: nil)
        let keys = try o.array("manifest_keys").map { try ManifestKey(base64: try $0.asString()) }
        return AltTrust(nitroRoots: [try o.base64("nitro_root")], manifestKeys: keys)
    }

    /// The portal's half of MEMBER-API 2.0.0 against the member API stand-in: a setup code's secret for [guid]
    /// (`POST /api/vault/enroll-code` with the portal session `Authorization: Bearer <user_guid>`).
    public func issueSetupCode(guid: String) async throws -> String {
        let (status, o) = try await call("POST", apiBase + "/api/vault/enroll-code", body: [], bearer: guid)
        guard status / 100 == 2 else { throw DevStackError("enroll-code: \(status)") }
        return try o.string("secret")
    }

    /// `vaultctl request TYPE BODY` on the peer (`POST /dev/peer/request`): the response's body. [body] is a JSON object.
    @discardableResult
    public func peerRequest(_ type: String, body: String = "{}") async throws -> JsonObject {
        let req = JsonBuilder().string("type", type).raw("body", body).build()
        let (status, o) = try await call("POST", control + "/dev/peer/request", body: Array(req.utf8))
        guard status == 200, try o.optString("status") == "ok" else { throw DevStackError("peer \(type): \(status)") }
        return try o.optObj("body") ?? StrictJson.parseObject("{}")
    }

    /// Waits for a peer event of [type] whose body has the [match] members (`POST /dev/peer/event`); its body.
    public func peerEvent(_ type: String, match: [String: String] = [:], timeoutSeconds: Int = 120) async throws -> JsonObject {
        let m = match.keys.sorted().reduce(JsonBuilder()) { $0.string($1, match[$1] ?? "") }.build()
        let req = JsonBuilder().string("type", type).raw("match", m).uint("timeout_s", UInt64(timeoutSeconds)).build()
        let (status, o) = try await call("POST", control + "/dev/peer/event", body: Array(req.utf8))
        guard status == 200 else { throw DevStackError("peer event \(type): \(status)") }
        return try o.optObj("body") ?? StrictJson.parseObject("{}")
    }

    /// The peer's active connection ids (`connection.list`).
    public func peerActiveConnections() async throws -> Set<String> {
        let list = try await peerRequest("connection.list").optArray("connections") ?? []
        return Set(try list.compactMap { v -> String? in
            let c = try v.asObject()
            return try c.optString("state") == "active" ? try c.optString("id") : nil
        })
    }

    /// Waits until the peer has an active connection that [known] does not hold, and returns its id (its
    /// `connection.event{added}` arrives while its own `connection.approve` runs and is not kept).
    public func peerAwaitNewConnection(known: Set<String>, timeoutSeconds: Int = 120) async throws -> String {
        let until = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < until {
            if let id = try await peerActiveConnections().subtracting(known).first { return id }
            try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1e9))
        }
        throw DevStackError("peer: no new active connection")
    }

    /// Waits for a peer connection request with a safety code (`connection.request.list`): [direction] `incoming` or
    /// `outgoing`, matching [connectionID] when given.
    public func peerRequestWithSas(direction: String, connectionID: String? = nil, timeoutSeconds: Int = 120) async throws -> JsonObject {
        let until = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < until {
            for v in try await peerRequest("connection.request.list").optArray(direction) ?? [] {
                let r = try v.asObject()
                let id = try r.optString("connection_id")
                if connectionID == nil || id == connectionID, r.has("sas") { return r }
            }
            try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1e9))
        }
        throw DevStackError("peer: no \(direction) request with a safety code")
    }

    private func call(_ method: String, _ urlString: String, body: [UInt8]?, bearer: String? = nil) async throws -> (Int, JsonObject) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let a = try await transport.send(policy: method == "GET" ? .idempotent : .never, maxBody: Self.maxBody) {
            var r = URLRequest(url: url)
            r.httpMethod = method
            if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            if let body {
                r.httpBody = Data(body)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return r
        }
        return (a.status, a.body.isEmpty ? try StrictJson.parseObject("{}") : try StrictJson.parseObject(a.body))
    }
}

/// The dev stack did not answer as expected.
public struct DevStackError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) { self.description = "\(DevStack.testOnlyMarker): \(description)" }
}

/// TEST ONLY. An app key in software (ECDSA P-256), where the app uses the Secure Enclave's (VAULT-MESSAGING §11.12.2).
/// Mirrors vettid-android `SoftwareAppKey`.
public struct SoftwareAppKey: AppKeySigner, CustomStringConvertible {
    public static let testOnlyMarker = "VETTID TEST ONLY: a software app key instead of the Secure Enclave's"
    private let signing: P256.Signing.PrivateKey

    public var description: String { Self.testOnlyMarker }

    public init() { signing = P256.Signing.PrivateKey() }

    public func spki() throws -> [UInt8] { Array(signing.publicKey.derRepresentation) }

    public func sign(_ message: [UInt8]) throws -> [UInt8] { Array(try signing.signature(for: message).derRepresentation) }
}
