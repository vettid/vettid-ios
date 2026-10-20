import XCTest

/// IOS-PLAN §8 exit I1 (a): on the simulator, the VettIDDevStack app (DevStack configuration, the TEST App Attest attester
/// and software keys; AppDevStack/DevStackWiring.swift) against the local dev stack, all through its screens: a fresh
/// install, the typed setup code, the PIN, the credential password, the finished setup, then "Lock vault", the unlock with
/// the PIN, the open app, and the vault locked again.
///
/// Run by `scripts/devstack-test.sh --ui`, which starts the stack, removes the app from the simulator, issues a setup code
/// for a new member just before the run (MEMBER-API 2.0.0's `POST /api/vault/enroll-code`, as VettIDAltChanTesting's
/// `DevStack.issueSetupCode` does) and hands the test runner, as `TEST_RUNNER_<NAME>`:
///
/// - `VETTID_DEVSTACK_API`, `VETTID_DEVSTACK_RELAY`, `VETTID_DEVSTACK_CTL`: the stack's addresses from its
///   `run/ready.json`;
/// - `VETTID_DEVSTACK_NITRO_ROOT`, `VETTID_DEVSTACK_MANIFEST_KEYS`: its TEST-ONLY trust (`GET /dev/trust`);
/// - `VETTID_DEVSTACK_EMAIL`, `VETTID_DEVSTACK_CODE`: the new member's address and typed code.
///
/// The addresses and the trust go on to the app in its launch environment. Skipped without them, unless the script runs
/// it (`VETTID_DEVSTACK_UI=1`), which makes a missing input a failure. Everything here is TEST-ONLY: the member, the
/// code, the PIN and the password exist only on the dev stack.
final class DevStackTests: VaultUITestCase {
    /// The dev stack's enclave starts on a small VM: an unlock or a lock may wait for it.
    override static var network: TimeInterval { 180 }
    static let pin = "97531086"
    static let password = "lantern quietly orbits 7 violet harbors"
    /// What the app needs from the runner's environment, passed on unchanged.
    static let forwarded = [
        "VETTID_DEVSTACK_API", "VETTID_DEVSTACK_RELAY", "VETTID_DEVSTACK_CTL", "VETTID_DEVSTACK_NITRO_ROOT",
        "VETTID_DEVSTACK_MANIFEST_KEYS",
    ]

    @MainActor
    func testDevStackEnrollLockUnlock() throws {
        var environment: [String: String] = [:]
        for name in Self.forwarded { environment[name] = try Self.input(name) }
        let email = try Self.input("VETTID_DEVSTACK_EMAIL")
        let code = try Self.input("VETTID_DEVSTACK_CODE")

        let app = launch(environment: environment)
        let start = waitForAny(app, ["welcome_recover", "unlock", "app_shell"], timeout: 60)
        guard start == "welcome_recover" else {
            return fail(app, "Not a fresh app: \(start ?? "no known screen") is shown. Remove VettID Dev Stack first.")
        }

        enroll(app, email: email, code: code, pin: Self.pin, password: Self.password)
        lock(app)
        unlock(app, pin: Self.pin, password: Self.password)
        XCTAssertTrue(app.descendants(matching: .any)["app_shell"].exists, "the vault is not open after the unlock")
        lock(app)
    }

    /// An input from the runner's environment (xcodebuild hands `TEST_RUNNER_<NAME>` over as `<NAME>`). Without it the
    /// test is skipped, except when the script runs it (`VETTID_DEVSTACK_UI=1`): then a missing input fails it, so that
    /// `--ui` never passes on a test that did not run.
    static func input(_ name: String) throws -> String {
        let env = ProcessInfo.processInfo.environment
        guard let value = env[name], !value.isEmpty else {
            if env["VETTID_DEVSTACK_UI"] == "1" { throw MissingInput(name: name) }
            throw XCTSkip("\(name) is not set: the dev stack UI test runs only through scripts/devstack-test.sh --ui")
        }
        return value
    }

    struct MissingInput: Error, CustomStringConvertible {
        let name: String

        var description: String { "\(name) is not set although scripts/devstack-test.sh --ui runs the test" }
    }
}
