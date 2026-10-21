import Foundation
import VettIDVault

/// The devices the sessions of a vault manager held, weakly: one that nothing holds any more is gone, and one a request
/// on its way still holds can be forgotten before a wipe erases the files (its save is then refused).
@MainActor
final class MadeDevices {
    private struct Ref {
        weak var device: VaultDevice?
    }

    private var refs: [Ref] = []

    func add(_ d: VaultDevice) {
        refs.removeAll { $0.device == nil || $0.device === d }
        refs.append(Ref(device: d))
    }

    var alive: [VaultDevice] { refs.compactMap(\.device) }

    func removeAll() { refs = [] }
}
