import Foundation

@MainActor
final class RequestPaymentViewModel: ObservableObject {

    @Published var amountBtc: String = ""
    @Published var memo: String = ""
    @Published var selectedConnectionId: String?
    @Published var connections: [NatsConnectionRecord] = []
    @Published var wallets: [WalletInfo] = []
    @Published var selectedWalletId: String?
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var didSend = false

    var walletClient: WalletClient?
    var connectionsClient: ConnectionsClient?

    var amountSats: Int64 {
        guard let decimal = Decimal(string: amountBtc) else { return 0 }
        let sats = decimal * 100_000_000
        return NSDecimalNumber(decimal: sats).int64Value
    }

    var satsDisplay: String {
        let sats = amountSats
        if sats == 0 && !amountBtc.isEmpty { return "Invalid" }
        return "\(sats) sats"
    }

    var canSend: Bool {
        selectedConnectionId != nil
            && selectedWalletId != nil
            && amountSats > 0
            && !isSending
    }

    func loadData() async {
        do {
            if let wc = walletClient {
                wallets = try await wc.listWallets()
                if wallets.count == 1 {
                    selectedWalletId = wallets.first?.walletId
                }
            }
            if let cc = connectionsClient {
                let result = try await cc.list(status: "active")
                connections = result.items
            }
        } catch {
            #if DEBUG
            print("[RequestPaymentVM] Load failed: \(error)")
            #endif
        }
    }

    func sendRequest() async {
        guard canSend,
              let client = walletClient,
              let connectionId = selectedConnectionId,
              let walletId = selectedWalletId else { return }

        isSending = true
        errorMessage = nil

        do {
            try await client.requestPayment(
                connectionId: connectionId,
                walletId: walletId,
                amountSats: amountSats,
                memo: memo.isEmpty ? nil : memo
            )
            didSend = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isSending = false
    }
}
