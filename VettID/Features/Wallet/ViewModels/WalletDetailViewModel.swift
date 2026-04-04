import Foundation

@MainActor
final class WalletDetailViewModel: ObservableObject {

    enum State {
        case loading
        case loaded
        case error(String)
    }

    @Published var state: State = .loading
    @Published var wallet: WalletInfo?
    @Published var balance: BalanceInfo?
    @Published var transactions: [TxHistoryEntry] = []
    @Published var showVisibilityWarning = false

    var walletClient: WalletClient?

    func loadDetail(walletId: String) async {
        state = .loading
        do {
            guard let client = walletClient else {
                state = .error("Wallet service unavailable")
                return
            }

            async let balanceResult = client.getBalance(walletId: walletId)
            async let historyResult = client.getHistory(walletId: walletId, limit: 50)

            balance = try await balanceResult
            transactions = try await historyResult
            state = .loaded
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func refreshBalance() async {
        guard let client = walletClient, let wallet = wallet else { return }
        do {
            balance = try await client.getBalance(walletId: wallet.walletId)
        } catch {
            #if DEBUG
            print("[WalletDetailVM] Refresh balance failed: \(error)")
            #endif
        }
    }

    func refreshHistory() async {
        guard let client = walletClient, let wallet = wallet else { return }
        do {
            transactions = try await client.getHistory(walletId: wallet.walletId, limit: 50)
        } catch {
            #if DEBUG
            print("[WalletDetailVM] Refresh history failed: \(error)")
            #endif
        }
    }

    func toggleVisibility() async {
        guard let client = walletClient, let wallet = wallet else { return }

        // Making a wallet public cannot be undone — show warning first
        if !wallet.isPublic {
            showVisibilityWarning = true
            return
        }

        await performVisibilityChange(isPublic: false)
    }

    func confirmMakePublic() async {
        showVisibilityWarning = false
        await performVisibilityChange(isPublic: true)
    }

    private func performVisibilityChange(isPublic: Bool) async {
        guard let client = walletClient, let wallet = wallet else { return }
        do {
            _ = try await client.setVisibility(walletId: wallet.walletId, isPublic: isPublic)
            // Update local state
            self.wallet = WalletInfo(
                walletId: wallet.walletId,
                label: wallet.label,
                address: wallet.address,
                network: wallet.network,
                cachedBalanceSats: wallet.cachedBalanceSats,
                balanceUpdatedAt: wallet.balanceUpdatedAt,
                isPublic: isPublic,
                isArchived: wallet.isArchived
            )
        } catch {
            #if DEBUG
            print("[WalletDetailVM] Visibility change failed: \(error)")
            #endif
        }
    }
}
