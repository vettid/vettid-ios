import Foundation

@MainActor
final class SendBtcViewModel: ObservableObject {

    enum SendStep {
        case selectWallet
        case enterRecipient
        case enterAmount
        case selectFee
        case review
        case sending
        case success(TxResult)
        case error(String)
    }

    @Published var step: SendStep = .enterRecipient
    @Published var wallets: [WalletInfo] = []
    @Published var selectedWallet: WalletInfo?
    @Published var recipientAddress: String = ""
    @Published var addressError: String?
    @Published var amountBtc: String = ""
    @Published var selectedFeeTier: FeeTier = .standard
    @Published var feeEstimate: FeeEstimate?

    var walletClient: WalletClient?

    /// Amount in satoshis derived from the BTC input (uses Decimal to avoid rounding errors)
    var amountSats: Int64 {
        guard let decimal = Decimal(string: amountBtc) else { return 0 }
        let sats = decimal * 100_000_000
        return NSDecimalNumber(decimal: sats).int64Value
    }

    /// Formatted sats display for the current BTC input
    var satsDisplay: String {
        let sats = amountSats
        if sats == 0 && !amountBtc.isEmpty { return "Invalid" }
        return "\(sats) sats"
    }

    /// Selected fee rate in sat/vB
    var selectedFeeRate: Int? {
        guard let estimate = feeEstimate else { return nil }
        return selectedFeeTier.rate(from: estimate)
    }

    /// Whether the user can proceed to review
    var canReview: Bool {
        selectedWallet != nil
            && !recipientAddress.isEmpty
            && amountSats > 0
            && amountSats <= (selectedWallet?.cachedBalanceSats ?? 0)
            && feeEstimate != nil
    }

    // MARK: - Actions

    func loadWallets() async {
        guard let client = walletClient else { return }
        do {
            wallets = try await client.listWallets()
            // Auto-select if only one wallet
            if wallets.count == 1 {
                selectedWallet = wallets.first
            } else if wallets.count > 1 && selectedWallet == nil {
                step = .selectWallet
                return
            }
        } catch {
            step = .error(error.localizedDescription)
        }
    }

    func loadFeeEstimates() async {
        guard let client = walletClient else { return }
        do {
            feeEstimate = try await client.getFeeEstimates()
        } catch {
            #if DEBUG
            print("[SendBtcVM] Fee estimate failed: \(error)")
            #endif
        }
    }

    func selectWallet(_ wallet: WalletInfo) {
        selectedWallet = wallet
        step = .enterRecipient
    }

    func proceedToAmount() {
        guard isValidBitcoinAddress(recipientAddress) else {
            addressError = "Invalid Bitcoin address"
            return
        }
        addressError = nil
        step = .enterAmount
    }

    private func isValidBitcoinAddress(_ address: String) -> Bool {
        // Mainnet: starts with 1, 3, or bc1; Testnet: starts with m, n, 2, or tb1
        let patterns = [
            "^(1|3)[a-km-zA-HJ-NP-Z1-9]{25,34}$",
            "^bc1[a-z0-9]{39,59}$",
            "^(m|n|2)[a-km-zA-HJ-NP-Z1-9]{25,34}$",
            "^tb1[a-z0-9]{39,59}$",
        ]
        return patterns.contains { address.range(of: $0, options: .regularExpression) != nil }
    }

    func proceedToFee() {
        step = .selectFee
    }

    func proceedToReview() {
        guard canReview else { return }
        step = .review
    }

    func send() async {
        guard let client = walletClient,
              let wallet = selectedWallet,
              amountSats > 0 else { return }

        step = .sending

        do {
            let result = try await client.send(
                walletId: wallet.walletId,
                toAddress: recipientAddress,
                amountSats: amountSats,
                feeRate: selectedFeeRate
            )
            step = .success(result)
        } catch {
            step = .error(error.localizedDescription)
        }
    }

    func goBack() {
        switch step {
        case .enterRecipient: break
        case .enterAmount: step = .enterRecipient
        case .selectFee: step = .enterAmount
        case .review: step = .selectFee
        default: break
        }
    }

    func reset() {
        step = .enterRecipient
        recipientAddress = ""
        amountBtc = ""
        selectedFeeTier = .standard
        addressError = nil
    }
}
