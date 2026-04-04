import SwiftUI

/// Bottom sheet action for requesting payment from a peer in a conversation.
struct ConversationRequestPaymentAction: View {

    let connectionId: String
    var walletClient: WalletClient?
    var onDismiss: (() -> Void)?

    @State private var amountBtc: String = ""
    @State private var memo: String = ""
    @State private var wallets: [WalletInfo] = []
    @State private var selectedWalletId: String?
    @State private var isSending = false
    @State private var errorMessage: String?

    private var amountSats: Int64 {
        guard let btc = Double(amountBtc) else { return 0 }
        return Int64(btc * 100_000_000)
    }

    private var canSend: Bool {
        selectedWalletId != nil && amountSats > 0 && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("0.00000000", text: $amountBtc)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.decimalPad)
                    if amountSats > 0 {
                        Text("\(amountSats) sats")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Amount (BTC)")
                }

                Section {
                    TextField("Optional memo", text: $memo, axis: .vertical)
                        .lineLimit(1...2)
                } header: {
                    Text("Memo")
                }

                if !wallets.isEmpty {
                    Section {
                        Picker("Wallet", selection: $selectedWalletId) {
                            Text("Select wallet").tag(nil as String?)
                            ForEach(wallets) { wallet in
                                Text(wallet.label).tag(wallet.walletId as String?)
                            }
                        }
                    } header: {
                        Text("Receive To")
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Request Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss?() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await sendRequest() }
                    }
                    .disabled(!canSend)
                }
            }
        }
        .task {
            await loadWallets()
        }
        .presentationDetents([.medium])
    }

    private func loadWallets() async {
        guard let client = walletClient else { return }
        do {
            wallets = try await client.listWallets()
            if wallets.count == 1 {
                selectedWalletId = wallets.first?.walletId
            }
        } catch {
            #if DEBUG
            print("[RequestPaymentAction] Load wallets failed: \(error)")
            #endif
        }
    }

    private func sendRequest() async {
        guard canSend,
              let client = walletClient,
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
            onDismiss?()
        } catch {
            errorMessage = error.localizedDescription
        }

        isSending = false
    }
}
