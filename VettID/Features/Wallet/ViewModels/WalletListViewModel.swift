import Foundation

@MainActor
final class WalletListViewModel: ObservableObject {

    enum State {
        case loading
        case empty
        case loaded([WalletInfo])
        case error(String)
    }

    @Published var state: State = .loading

    var walletClient: WalletClient?

    func loadWallets() async {
        state = .loading
        do {
            guard let client = walletClient else {
                state = .error("Wallet service unavailable")
                return
            }
            let wallets = try await client.listWallets()
            if wallets.isEmpty {
                state = .empty
            } else {
                state = .loaded(wallets)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func refresh() async {
        guard let client = walletClient else { return }
        do {
            let wallets = try await client.listWallets()
            state = wallets.isEmpty ? .empty : .loaded(wallets)
        } catch {
            // Keep existing state on refresh failure
            #if DEBUG
            print("[WalletListVM] Refresh failed: \(error)")
            #endif
        }
    }
}
