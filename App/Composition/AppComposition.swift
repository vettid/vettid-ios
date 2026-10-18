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
    static let shared = AppComposition(environment: .current)

    let environment: AppEnvironment
    let protectedData = ProtectedDataMonitor()
    let inbox = SetupLinkInbox()
    let firstRun: FirstRunGate
    let vault: VaultManager

    init(environment: AppEnvironment) {
        self.environment = environment
        let directory = Self.dataDirectory()
        let hardware = PendingSecureHardware()
        let keys = VaultKeys(
            appKeys: hardware, seedWrap: hardware, wrapped: KeychainWrappedKeyStore(protectedData: protectedData),
            phone: hardware, files: KeychainFileKeyHolder(protectedData: protectedData)
        )
        // §6.1: every VettID keychain item, then each key source through its protocol; refused while the vault
        // manager's files exist.
        firstRun = FirstRunGate(FirstRunCleanup(
            directory: directory, protectedData: protectedData, erasers: [KeychainEraser(), hardware],
            dataFiles: VaultFiles.all(in: directory)
        ))
        let trust: AltTrust
        do {
            trust = try environment.trust()
        } catch {
            preconditionFailure("the build's manifest keys do not parse")
        }
        let gate = firstRun
        vault = VaultManager(config: VaultManagerConfig(
            apiOrigin: environment.apiOrigin,
            manifestURL: environment.manifestURL,
            relayURL: environment.relayURL,
            trust: trust,
            // The dev stack's relay address mapping (DevStack only) comes with I1.3.
            transport: HTTPTransport(session: URLSession(configuration: .ephemeral)),
            directory: directory,
            keys: keys,
            attester: hardware,
            protectedData: protectedData,
            enrolledAttestation: .nitro(roots: trust.nitroRoots),
            deviceName: UIDevice.current.model,
            prepare: { try gate.ensure() }
        ))
    }

    /// At launch, before anything else touches a key: protected data is followed, and the first-run cleanup runs
    /// (deferred, and run again before the first key is touched, while the iPhone has not been unlocked since it
    /// started).
    func launch() {
        protectedData.start()
        _ = try? firstRun.ensure()
    }

    /// `Application Support/VettID` (IOS-PLAN §6.1), excluded from backups when the files are written.
    private static func dataDirectory() -> URL {
        if let dir = try? AppDirectories.data() { return dir }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(AppDirectories.dataFolder)")
    }
}
