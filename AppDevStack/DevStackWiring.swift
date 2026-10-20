#if !VETTID_DEVSTACK_APP
#error("AppDevStack is compiled only into the VettIDDevStack app, in its DevStack configuration")
#endif

import Foundation
import VettIDAltChan
import VettIDAltChanTesting
import VettIDAttestation
import VettIDKeys
import VettIDKeysTesting
import VettIDRelay

/// TEST ONLY. The wiring of the VettIDDevStack app (IOS-PLAN §5 "Build configurations", §8 exit I1 (a)): the app's own
/// screens and vault manager against the local dev stack (vettid-vault `cmd/devstack`, `scripts/devstack-test.sh`) on
/// the simulator, which has neither a Secure Enclave nor App Attest. So, as the vault has no relaxed App Attest mode
/// (IOS-PLAN §6.2), it composes VettIDAltChanTesting's TEST iOS attester, which only the dev enclave's TEST policy
/// accepts, VettIDKeysTesting's software keys (IOS-PLAN §6.1, §6.3), and the stack's TEST-ONLY trust anchors.
///
/// Only the VettIDDevStack target compiles this file and links those modules, and only in its DevStack configuration
/// (the `#error` above, `VETTID_DEVSTACK_APP` in project.yml); the VettID app, Release and Staging included, never does
/// (scripts/release-check.sh). The software keys live in memory: a vault enrolled by this app lasts as long as the app
/// runs (and no vault survives a restart of the stack either), which is what the UI test needs.
///
/// The addresses come from the launch environment (the UI test sets them from the stack's `run/ready.json`), else the
/// dev stack's defaults:
///
/// - `VETTID_DEVSTACK_API`, `VETTID_DEVSTACK_RELAY`, `VETTID_DEVSTACK_CTL`: the member API, the relay's plain-HTTP port
///   and the control port (VettIDAltChanTesting's `DevStack.fromEnvironment`);
/// - `VETTID_DEVSTACK_NITRO_ROOT` (base64 DER) and `VETTID_DEVSTACK_MANIFEST_KEYS` (base64 SPKI, comma-separated): the
///   stack's `GET /dev/trust`; without them the app asks the control port itself at launch.
enum DevStackWiring {
    /// The marker the release check refuses in a Release or Staging app.
    static let testOnlyMarker = "VETTID TEST ONLY: the dev stack app's wiring"
    static let nitroRootName = "VETTID_DEVSTACK_NITRO_ROOT"
    static let manifestKeysName = "VETTID_DEVSTACK_MANIFEST_KEYS"
    /// How long a launch without the trust in its environment waits for the control port.
    static let trustWait: TimeInterval = 10

    static let stack = DevStack.fromEnvironment()

    /// The DevStack configuration's environment, with the member API (where the manifest is served too) of the stack.
    static let environment: AppEnvironment = {
        var info = Bundle.main.infoDictionary ?? [:]
        if let api = URLComponents(string: stack.apiBase), let host = api.host {
            let address = api.port.map { "\(host):\($0)" } ?? host
            info["VettIDAccountHost"] = address
            info["VettIDManifestHost"] = address
        }
        guard let env = AppEnvironment(infoDictionary: info), env.kind == .devstack else {
            preconditionFailure("\(testOnlyMarker): not the DevStack configuration")
        }
        return env
    }()

    @MainActor
    static func wiring() -> AppWiring {
        // Said once at launch, and so kept in the binary whatever the optimizer drops (the release check refuses it).
        NSLog("%@", testOnlyMarker)
        return AppWiring(
            hardware: { _, _ in hardware() },
            // The relay URL that tokens name (`https://relay.vettid.test`) goes to the relay's plain-HTTP port.
            transport: HTTPTransport(
                session: URLSession(configuration: .ephemeral), originMap: [environment.relayURL: stack.relayTransport]
            ),
            trust: trust()
        )
    }

    /// The TEST attester and software keys behind the protocols of the Secure Enclave's. No app-lock key: the app lock
    /// stays off, as on a phone without a Secure Enclave.
    static func hardware() -> HardwareKeys {
        let appKeys = SoftwareAppKeyStore()
        let seedWrap = SoftwareSeedWrapKeySource()
        let phone = SoftwarePhoneSecretSource()
        return HardwareKeys(
            appKeys: appKeys, seedWrap: seedWrap, phone: phone, attester: TestIOSAttester(), appLock: NoAppLockKeys(),
            erasers: [appKeys, seedWrap, phone]
        )
    }

    /// The stack's TEST-ONLY Nitro root and manifest keys, with the dev stack's time scales.
    static func trust() -> AltTrust {
        let env = ProcessInfo.processInfo.environment
        let fetched: AltTrust
        if let root = env[nitroRootName].flatMap({ Data(base64Encoded: $0) }), let keys = env[manifestKeysName] {
            do {
                let parsed = try keys.split(separator: ",").map { try ManifestKey(base64: String($0)) }
                fetched = AltTrust(nitroRoots: [Array(root)], manifestKeys: parsed)
            } catch {
                preconditionFailure("\(testOnlyMarker): \(manifestKeysName) does not parse")
            }
        } else {
            guard let asked = askControlPort() else {
                preconditionFailure("\(testOnlyMarker): the dev stack's control port \(stack.control) did not answer")
            }
            fetched = asked
        }
        return AltTrust(nitroRoots: fetched.nitroRoots, manifestKeys: fetched.manifestKeys, timeScales: environment.timeScales)
    }

    /// `GET /dev/trust`, waited for at launch (a development build started by hand).
    private static func askControlPort() -> AltTrust? {
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            answer.value = try? await stack.trust()
            done.signal()
        }
        _ = done.wait(timeout: .now() + trustWait)
        return answer.value
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AltTrust?

        var value: AltTrust? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
