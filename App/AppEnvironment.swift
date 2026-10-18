import Foundation
import VettIDAltChan
import VettIDAttestation

/// The environment a build talks to, fixed by its build configuration
/// (IOS-PLAN §5 "Build configurations"). The values come from
/// `Config/<configuration>.xcconfig` through the app's Info.plist.
struct AppEnvironment: Equatable, Sendable {
    enum Kind: String, Sendable {
        case production
        case staging
        case debug
        case devstack

        /// The development builds (Debug, DevStack) allow screenshots from the start (ID10, the screen catalog).
        var screenshotsByDefault: Bool { self == .debug || self == .devstack }
    }

    let kind: Kind
    let accountHost: String
    /// The relay's host (`relay.vettid.org`; the dev stack's `relay.vettid.test`, mapped to its port).
    let relayHost: String
    /// Where the release manifest is served (`vettid.org`, `staging.vettid.org`; the dev stack's member API).
    let manifestHost: String
    /// The manifest keys a Staging, Debug or DevStack build pins (SPKI DER, base64, comma-separated): the staging
    /// channel's key A in Staging and Debug. Release ignores it and pins ``ManifestKeys/production``, which is in code.
    let manifestKeys: [String]

    /// Reads the environment from an Info.plist dictionary; `nil` when a
    /// key is missing or unknown.
    init?(infoDictionary: [String: Any]) {
        guard
            let raw = infoDictionary["VettIDEnvironment"] as? String,
            let kind = Kind(rawValue: raw),
            let host = infoDictionary["VettIDAccountHost"] as? String,
            !host.isEmpty,
            let relay = infoDictionary["VettIDRelayHost"] as? String,
            !relay.isEmpty,
            let manifest = infoDictionary["VettIDManifestHost"] as? String,
            !manifest.isEmpty
        else { return nil }
        self.kind = kind
        self.accountHost = host
        self.relayHost = relay
        self.manifestHost = manifest
        let keys = (infoDictionary["VettIDManifestKeys"] as? String) ?? ""
        self.manifestKeys = keys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// This build's environment. A build without one is misconfigured.
    static let current: AppEnvironment = {
        guard let env = AppEnvironment(infoDictionary: Bundle.main.infoDictionary ?? [:]) else {
            preconditionFailure("Info.plist lacks the VettID environment keys")
        }
        return env
    }()

    /// The dev stack's member API and manifest are plain HTTP on the Mac (vettid-vault `cmd/devstack`); everything
    /// else is HTTPS.
    private var scheme: String { kind == .devstack ? "http" : "https" }

    /// The member API origin, which setup codes name exactly (VAULT-MESSAGING §11.12.1).
    var apiOrigin: String { "\(scheme)://\(accountHost)" }

    var manifestURL: String { "\(scheme)://\(manifestHost)\(MemberApiClient.manifestPath)" }

    /// The relay base URL tokens name (`aud`): always HTTPS (the dev stack maps it to its port).
    var relayURL: String { "https://\(relayHost)" }

    /// The pinned Nitro root and manifest keys (§11.2, §11.10.1): production's in Release; the staging channel's key A
    /// in Staging and Debug. The dev stack's TEST-ONLY anchors come from its control port (VettIDAltChanTesting's
    /// DevStack); until an app target links it, a DevStack build pins what Debug pins and verifies nothing the dev stack
    /// serves.
    func trust() throws -> AltTrust {
        guard kind != .production else { return .production }
        return AltTrust(nitroRoots: [NitroRoot.der], manifestKeys: try manifestKeys.map { try ManifestKey(base64: $0) })
    }
}
