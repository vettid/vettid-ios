import Foundation

@MainActor
final class ReceiveBtcViewModel: ObservableObject {

    @Published var address: String = ""
    @Published var walletLabel: String = ""
    @Published var isLoading = true
    @Published var errorMessage: String?

    var walletClient: WalletClient?

    func loadAddress(wallet: WalletInfo) async {
        walletLabel = wallet.label
        address = wallet.address
        errorMessage = nil
        isLoading = address.isEmpty

        // Fetch fresh address from vault
        guard let client = walletClient else {
            if address.isEmpty {
                errorMessage = "Wallet service unavailable"
                isLoading = false
            }
            return
        }
        do {
            address = try await client.getAddress(walletId: wallet.walletId)
        } catch {
            if address.isEmpty {
                errorMessage = error.localizedDescription
            }
            #if DEBUG
            print("[ReceiveBtcVM] Failed to fetch fresh address: \(error)")
            #endif
        }
        isLoading = false
    }
}
