import Foundation
import VettIDData

/// What the calls' wiring needs of the app's vault beyond ``CallVault``: a hook before the member's lock.
@MainActor
package protocol CallsAppVault: CallVault {
    /// Whether the vault is open on this phone now (observable): the call screens are never over a vault that is not open, so they go
    /// with the first line of a lock, before the unlock screen comes.
    var isOpen: Bool { get }

    /// Something to finish while the vault still collects, before the member's lock (a live call's hang-up).
    func onBeforeLock(_ hook: @escaping @MainActor () async -> Void)

    /// The collection of the vault's messages goes on while [held] says so, when the app leaves the foreground (a live call).
    func holdCollection(_ held: @escaping @MainActor () -> Bool)

    /// [held] of ``holdCollection(_:)`` turned false: a background that waited for it may finish.
    func collectionHoldEnded()
}

/// The name a call shows for a connection: the names on its VettID account, else its display name, each cleaned first
/// (VAULT-MESSAGING §10.8), so that a name that shows nothing falls through to the next; nil when neither shows anything.
/// Mirrors vettid-android `callName`.
package func callName(_ c: ConnectionInfo) -> String? { AccountNames.cleaned(c.accountName) ?? AccountNames.cleaned(c.name) }

/// ``CallVault`` over the vault manager: its phase, its typed client and its connections as the app shows them (vettid-android
/// `CallsModule.ManagerVault`).
@MainActor
package final class ManagerVault: CallsAppVault {
    private let manager: VaultManager
    package let gateway: any CallGateway

    package init(_ manager: VaultManager) {
        self.manager = manager
        // The client is asked each time: it is refused while the vault is not open on this phone or a lock is pending.
        // The hang-up goes also while a lock is pending (the phone is locked from the lock's first line, before the hook runs).
        gateway = VaultCallGateway(
            api: { [unowned manager] in try manager.callApi() },
            end: { [unowned manager] in try await manager.sendCallEnd(callId: $0, reason: $1) }
        )
    }

    /// A lock pending counts as locked: the manager's phase is `locked` from the first line of the member's lock. A vault
    /// that must first move to the current release (owner decision 2026-11-17, ``ReleaseUpdateManager/required``) counts as not open either:
    /// no call starts or rings until it has moved.
    package func unlockedChanges() -> AsyncStream<Bool> { observed { [manager] in Self.open(manager) } }

    package var updateShowing: Bool { manager.releaseUpdateShowing }

    /// As the notifications' gate (the shell not shown): the check's screen after a cancel, or a check due or held, also one
    /// known only from the clock (the manager's).
    package var ownerCheckShowing: Bool { manager.ownerCheckComesFirst }

    package var isOpen: Bool { Self.open(manager) }

    private static func open(_ manager: VaultManager) -> Bool { manager.phase == .unlocked && !manager.releaseUpdate.required }

    /// The daily check was done, or the connections were read: the vault answers now, if it did not before. (Not the current
    /// values: only a change.)
    package func rechecks() -> AsyncStream<Void> {
        let snapshots = observed(skippingCurrent: true) { [manager] in
            Recheck(check: manager.ownerChecks.ownerCheck, connections: manager.connections.connections)
        }
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await _ in snapshots { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Recheck: Equatable, Sendable {
        var check: OwnerCheckView?
        var connections: [ConnectionInfo]
    }

    package func refreshConnections() async { try? await manager.connections.refresh() }

    /// Only an active connection has an identity a call can be checked against.
    private func connection(_ id: String) -> ConnectionInfo? {
        manager.connections.connections.first { $0.id == id && $0.state == .active }
    }

    package func fingerprint(_ connectionId: String) async -> String? { connection(connectionId)?.keyFingerprint }

    package func name(_ connectionId: String) -> String? { connection(connectionId).flatMap(callName) }

    package func firstName(_ connectionId: String) -> String? { connection(connectionId).flatMap { AccountNames.cleaned($0.firstName) } }

    package func onBeforeLock(_ hook: @escaping @MainActor () async -> Void) { manager.onBeforeLock(hook) }

    package func holdCollection(_ held: @escaping @MainActor () -> Bool) { manager.holdCollection(held) }

    package func collectionHoldEnded() { manager.collectionHoldEnded() }
}
