#if DEBUG
import CryptoKit
import Foundation
import VettIDAttestation
import VettIDTesting

// TEST ONLY. The published release manifest and canary documents (VAULT-MESSAGING §11.10.1, VAULT-RELEASES §10.1
// step 9).
public extension FakeVaultService {
    /// The VAULT-MESSAGING §16 TEST manifest key: private scalar 32 × 0x21 (public, so never pinned by a build).
    static let testManifestSigner: P256.Signing.PrivateKey = {
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: 0x21, count: 32))
        } catch {
            preconditionFailure("the TEST manifest key")
        }
    }()

    /// The published manifest's serial (7 at the start); nil: nothing is published, the URL answers 404.
    var publishedSerial: UInt64? {
        get { locked { publishedSerialValue } }
        set { locked { publishedSerialValue = newValue } }
    }

    /// The published manifest cannot be fetched (no connection).
    var manifestOffline: Bool {
        get { locked { manifestOfflineValue } }
        set { locked { manifestOfflineValue = newValue } }
    }

    /// The published manifest is served but does not verify (bytes that are not a signed manifest).
    var manifestBroken: Bool {
        get { locked { manifestBrokenValue } }
        set { locked { manifestBrokenValue = newValue } }
    }

    /// How many times the published manifest was fetched.
    var manifestFetches: Int { locked { manifestFetchesValue } }

    /// A canary document: the served manifest of [serial], signed by the TEST key (or [signer]) and not published.
    func canaryDocument(serial: UInt64, signer: P256.Signing.PrivateKey? = nil) throws -> [UInt8] {
        try servedManifest(serial: serial, signer: signer)
    }
}

extension FakeVaultService {
    /// The member API's answer for the published manifest (under ``cond``).
    func manifestAnswer() -> FakeHTTPServer.Answer {
        manifestFetchesValue += 1
        if manifestOfflineValue { return .failure(.notConnectedToInternet) }
        if manifestBrokenValue { return .bytes(200, Array("not a manifest".utf8)) }
        guard let serial = publishedSerialValue else { return .json(404, #"{"error":"not_found"}"#) }
        let served = try? servedManifest(serial: serial, release4: releases.listed4, release3: !releases.delisted3)
        return served.map { .bytes(200, $0) } ?? .empty(500)
    }
}
#endif
