import SwiftUI

struct RequestPaymentSheet: View {

    var walletClient: WalletClient?
    var connectionsClient: ConnectionsClient?

    @StateObject private var viewModel = RequestPaymentViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("0.00000000", text: $viewModel.amountBtc)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.decimalPad)
                    Text(viewModel.satsDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Amount (BTC)")
                }

                Section {
                    TextField("Optional memo", text: $viewModel.memo, axis: .vertical)
                        .lineLimit(1...2)
                } header: {
                    Text("Memo")
                }

                Section {
                    if viewModel.wallets.isEmpty {
                        Text("No wallets available")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Wallet", selection: $viewModel.selectedWalletId) {
                            Text("Select wallet").tag(nil as String?)
                            ForEach(viewModel.wallets) { wallet in
                                Text(wallet.label).tag(wallet.walletId as String?)
                            }
                        }
                    }
                } header: {
                    Text("Receive To")
                }

                Section {
                    if viewModel.connections.isEmpty {
                        Text("No active connections")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Connection", selection: $viewModel.selectedConnectionId) {
                            Text("Select connection").tag(nil as String?)
                            ForEach(viewModel.connections, id: \.connectionId) { conn in
                                Text(conn.label).tag(conn.connectionId as String?)
                            }
                        }
                    }
                } header: {
                    Text("Request From")
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Request Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send Request") {
                        Task {
                            await viewModel.sendRequest()
                            if viewModel.didSend { dismiss() }
                        }
                    }
                    .disabled(!viewModel.canSend)
                }
            }
            .task {
                viewModel.walletClient = walletClient
                viewModel.connectionsClient = connectionsClient
                await viewModel.loadData()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
