import Foundation

@MainActor
final class CreateWalletViewModel: ObservableObject {

    @Published var label: String = ""
    @Published var network: BitcoinNetwork = .mainnet
    /// Phase 5.2: password gate on wallet creation. The vault
    /// rotates the credential CEK on success; without the password
    /// the request is refused.
    @Published var password: String = ""
    @Published var isCreating = false
    @Published var errorMessage: String?
    @Published var createdWallet: WalletInfo?

    var walletClient: WalletClient?

    var canCreate: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isCreating
    }

    func createWallet() async {
        guard canCreate, let client = walletClient else { return }

        isCreating = true
        errorMessage = nil

        do {
            createdWallet = try await client.createWallet(
                label: label.trimmingCharacters(in: .whitespaces),
                network: network,
                password: password
            )
            // Wipe the in-memory password the moment the round-trip
            // completes — the envelope it built is already on the wire.
            password = ""
        } catch {
            errorMessage = error.localizedDescription
        }

        isCreating = false
    }
}
