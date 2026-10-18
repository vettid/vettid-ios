import Foundation
import VettIDCrypto

/// A message from the vault: an event (no `re`) or a response.
public struct VaultMessage: Sendable, CustomStringConvertible {
    public let inner: Inner

    public init(inner: Inner) { self.inner = inner }

    public var type: String { inner.type }
    public var id: String { inner.id }
    public var ts: Date { inner.ts }
    /// The body bytes (`{}` when empty).
    public var body: [UInt8] { inner.body.isEmpty ? Array("{}".utf8) : inner.body }

    public var description: String { "VaultMessage(\(type))" }

    /// The body decoded leniently into [T] (§10.1: unknown members are ignored).
    public func decode<T: Decodable>(_: T.Type) throws -> T { try VaultJSON.decode(T.self, body) }

    /// The body as a strict JSON object (`{}` when it does not parse).
    public var object: JsonObject { VaultJSON.object(body) }
}

/// JSON for message bodies (§10.1: unknown members are ignored). Envelopes and inner plaintexts stay with the strict
/// parser; bodies the vault sends inside an authenticated session are decoded into the typed models with `Codable`.
public enum VaultJSON {
    public static func decode<T: Decodable>(_: T.Type, _ b: [UInt8]) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(T.self, from: Data(b.isEmpty ? Array("{}".utf8) : b))
    }

    public static func object(_ b: [UInt8]) -> JsonObject {
        (try? StrictJson.parseObject(b.isEmpty ? Array("{}".utf8) : b)) ?? (try? StrictJson.parseObject(Array("{}".utf8)))!
    }

    public static func string(_ o: JsonObject, _ k: String) -> String? {
        if case .string(_, let v)? = o[k] { return v }
        return nil
    }

    public static func int(_ o: JsonObject, _ k: String) -> Int64? {
        if case .number(let raw)? = o[k] { return Int64(raw) }
        return nil
    }

    public static func bool(_ o: JsonObject, _ k: String) -> Bool? {
        if case .bool(_, let v)? = o[k] { return v }
        return nil
    }

    public static let empty: [UInt8] = Array("{}".utf8)
}

/// A request answered with `status: error` (§10.1): [code] is the spec's code; [body] is the error response's body,
/// when the code carries one.
public struct VaultOpError: Error, Sendable, CustomStringConvertible {
    public let type: String
    public let code: String
    /// The error's `message` ("" without one).
    public let detail: String
    public let body: [UInt8]?

    public var description: String { "vault: \(type): \(code)" + (detail.isEmpty ? "" : " (\(detail))") }
}

/// The device is not (yet) paired with a vault, or the vault sent something it should not have.
public struct VaultStateError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public var description: String { "vault client: \(message)" }
}

/// The owner rejected this device's pairing or transfer on their phone after its `hs.fin` (`device.pair.rejected`,
/// VAULT-MESSAGING §6.7, 0.10.5). The device has dropped the handshake's epoch and the request token.
public struct PairingRejected: Error, Equatable, Sendable {}

/// The device's own keys (§3.2), from the Secure Enclave and the encrypted file store for the device's lifetime.
public final class DeviceSecrets: Sendable {
    public let identity: Ed25519PrivateKey
    public let kem: KemPrivateKey
    public let relay: Ed25519PrivateKey
    /// The public half of the app key (§11.12.2), SPKI DER.
    public let apiKey: [UInt8]?

    public init(identity: Ed25519PrivateKey, kem: KemPrivateKey, relay: Ed25519PrivateKey, apiKey: [UInt8]? = nil) {
        self.identity = identity
        self.kem = kem
        self.relay = relay
        self.apiKey = apiKey
    }

    public func destroy() {
        identity.destroy()
        kem.destroy()
        relay.destroy()
    }

    public static func generate() throws -> DeviceSecrets {
        DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate())
    }
}
