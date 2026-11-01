import Foundation
import UIKit
import VettIDAltChan
import VettIDData
import VettIDKeys
import VettIDRelay
import VettIDVault

/// The app's dependency wiring (vettid-android's Hilt `AppModule`): the build's environment (IOS-PLAN §5), the keys
/// behind their protocols, the first-run cleanup (§6.1) and the vault manager the screens use. One per process.
@MainActor
final class AppComposition {
    #if VETTID_DEVSTACK_APP
    /// The VettIDDevStack app (DevStack configuration, simulator): the TEST attester, software keys and the dev stack's
    /// addresses (AppDevStack/DevStackWiring.swift, compiled into that target only).
    static let shared = AppComposition(environment: DevStackWiring.environment, wiring: DevStackWiring.wiring())
    #else
    static let shared = AppComposition(environment: .current)
    #endif

    let environment: AppEnvironment
    let protectedData = ProtectedDataMonitor()
    let inbox = SetupLinkInbox()
    /// An invitation link the app was opened with (VAULT-MESSAGING §6.4), waiting for the open app's accept screen.
    let inviteInbox = InviteLinkInbox()
    /// A canary manifest opened with VettID or picked in Settings → Attestation, waiting for the root's dialog.
    let canaryInbox = CanaryManifestInbox()
    let firstRun: FirstRunGate
    let vault: VaultManager
    /// The app lock (ANDROID-PLAN D6, IOS-PLAN ID17): its key in the Secure Enclave; off where there is none
    /// (``NoAppLockKeys``).
    let appLock: AppLock
    /// The Secure Enclave keys and App Attest, or the refusing placeholder without them.
    let hardware: HardwareKeys
    /// What's new from the release log of the build's channel (RELEASE-UPDATES §5): only the pinned manifest's host.
    let releaseNotes: any ReleaseNotesRepository
    /// A request to open the update screen (fed by the "Vault updates" notification with phase P, IOS-PLAN §6.7).
    let releaseInbox = ReleaseUpdateInbox()

    /// The app's own wiring: the Secure Enclave and App Attest (or ``NoSecureHardware``), and the build's pinned trust.
    convenience init(environment: AppEnvironment) {
        let trust: AltTrust
        do {
            trust = try environment.trust()
        } catch {
            preconditionFailure("the build's manifest keys do not parse")
        }
        self.init(environment: environment, wiring: AppWiring(
            hardware: HardwareKeys.current(protectedData:startOver:),
            transport: HTTPTransport(session: URLSession(configuration: .ephemeral)),
            trust: trust
        ))
    }

    init(environment: AppEnvironment, wiring: AppWiring) {
        self.environment = environment
        let directory = Self.dataDirectory()
        // Whether a damaged App Attest key record may start over: the vault manager keeps it current.
        let startOver = AttestStartOver()
        let hardware = wiring.hardware(protectedData, startOver)
        self.hardware = hardware
        let keys = VaultKeys(
            appKeys: hardware.appKeys, seedWrap: hardware.seedWrap, wrapped: KeychainWrappedKeyStore(protectedData: protectedData),
            phone: hardware.phone, files: KeychainFileKeyHolder(protectedData: protectedData)
        )
        // §6.1: every VettID keychain item, then each key source through its protocol; refused while the vault
        // manager's files exist.
        firstRun = FirstRunGate(FirstRunCleanup(
            directory: directory, protectedData: protectedData, erasers: [KeychainEraser()] + hardware.erasers,
            dataFiles: VaultFiles.all(in: directory)
        ))
        let trust = wiring.trust
        let gate = firstRun
        var config = VaultManagerConfig(
            apiOrigin: environment.apiOrigin,
            manifestURL: environment.manifestURL,
            relayURL: environment.relayURL,
            trust: trust,
            transport: wiring.transport,
            directory: directory,
            keys: keys,
            attester: hardware.attester,
            protectedData: protectedData,
            enrolledAttestation: .nitro(roots: trust.nitroRoots),
            deviceName: UIDevice.current.model,
            prepare: { try gate.ensure() },
            wipeTargets: AppWipeTargets(data: directory, hardware: hardware.erasers),
            // Settings → Attestation names the environment this build talks to as vettid-android does (`PRODUCTION`, …).
            environment: environment.kind.rawValue.uppercased()
        )
        config.attestStartOver = startOver
        config.backgroundTasks = SystemBackgroundTasks()
        vault = VaultManager(config: config)
        releaseNotes = ReleaseNotesClient(manifestURL: environment.manifestURL)
        appLock = AppLock(
            store: FileAppLockStore(
                directory: directory, keys: KeychainFileKeyHolder(protectedData: protectedData), protectedData: protectedData
            ),
            keys: hardware.appLock
        )
        resetOnWipe()
    }

    /// A wipe resets what lives in memory: the app lock, a setup link waiting for the welcome screen, and a canary
    /// manifest waiting for its dialog or shown in it.
    private func resetOnWipe() {
        let lock = appLock
        let inbox = inbox
        let canaryInbox = canaryInbox
        vault.onWipe {
            lock.reset()
            inbox.consume()
            canaryInbox.reset()
        }
    }

    /// At launch, before anything else touches a key: protected data is followed, and the first-run cleanup runs
    /// (deferred, and run again before the first key is touched, while the iPhone has not been unlocked since it
    /// started).
    func launch() {
        protectedData.start()
        CanaryManifestFiles.sweepInbox()
        _ = try? firstRun.ensure()
        // A wipe a crash interrupted is finished before anything reads a local file (the app lock's included).
        if firstRun.isOpen { vault.resumePendingWipe() }
        startAppLock()
    }

    /// Reads the app lock's preferences once the first-run cleanup ran (before it, nothing is read); tried again when the
    /// app becomes active while it is still pending. The lock stays pending only while the iPhone has not been unlocked
    /// since it started: any other failure of the cleanup gives way to the root's screen that says so.
    func startAppLock() {
        guard appLock.state == .pending else { return }
        do {
            try firstRun.ensure()
        } catch KeysError.unavailable {
            return
        } catch {
            appLock.startFailed()
            return
        }
        vault.resumePendingWipe()
        appLock.start()
    }

    /// `Application Support/VettID` (IOS-PLAN §6.1), excluded from backups when the files are written.
    private static func dataDirectory() -> URL {
        if let dir = try? AppDirectories.data() { return dir }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(AppDirectories.dataFolder)")
    }
}

/// What a build composes besides its environment: its keys and attester, its transport and the trust anchors it pins.
struct AppWiring {
    /// The keys and attester, from the protected-data monitor and the App Attest start-over flag.
    let hardware: @MainActor (any ProtectedData, AttestStartOver) -> HardwareKeys
    let transport: HTTPTransport
    let trust: AltTrust
}

/// ``BackgroundTasks`` over the system's background tasks (as `leaveForeground` asks for them).
struct SystemBackgroundTasks: BackgroundTasks {
    @MainActor func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() }
        }
        return id == .invalid ? nil : id.rawValue
    }

    @MainActor func end(_ token: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}
