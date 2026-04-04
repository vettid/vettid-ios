import SwiftUI

struct WalletDetailView: View {

    let wallet: WalletInfo
    var walletClient: WalletClient?

    @StateObject private var viewModel = WalletDetailViewModel()

    @State private var showSend = false
    @State private var showReceive = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading wallet...")
            case .loaded:
                walletContent
            case .error(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task { await viewModel.loadDetail(walletId: wallet.walletId) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle(wallet.label)
        .task {
            viewModel.walletClient = walletClient
            viewModel.wallet = wallet
            await viewModel.loadDetail(walletId: wallet.walletId)
        }
        .refreshable {
            await viewModel.refreshBalance()
            await viewModel.refreshHistory()
        }
        .sheet(isPresented: $showSend) {
            NavigationStack {
                SendBtcView(walletClient: walletClient, preselectedWallet: wallet)
            }
        }
        .sheet(isPresented: $showReceive) {
            NavigationStack {
                ReceiveBtcView(wallet: wallet, walletClient: walletClient)
            }
        }
        .alert("Make Wallet Public?", isPresented: $viewModel.showVisibilityWarning) {
            Button("Make Public", role: .destructive) {
                Task { await viewModel.confirmMakePublic() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Making your wallet public allows connections to see your address. This cannot be undone.")
        }
    }

    // MARK: - Content

    private var walletContent: some View {
        List {
            // Balance section
            Section {
                VStack(spacing: 8) {
                    if let balance = viewModel.balance {
                        Text(balance.formattedTotal)
                            .font(.system(.title, design: .monospaced).weight(.bold))
                        HStack(spacing: 16) {
                            VStack {
                                Text("Confirmed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(balance.confirmedSats) sats")
                                    .font(.caption.weight(.medium))
                            }
                            VStack {
                                Text("Unconfirmed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(balance.unconfirmedSats) sats")
                                    .font(.caption.weight(.medium))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // Actions
            Section {
                HStack(spacing: 16) {
                    Button(action: { showSend = true }) {
                        Label("Send", systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { showReceive = true }) {
                        Label("Receive", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .padding(.vertical, 4)
            }

            // Visibility
            if let currentWallet = viewModel.wallet {
                Section {
                    HStack {
                        Label(currentWallet.isPublic ? "Public" : "Private", systemImage: currentWallet.isPublic ? "eye" : "eye.slash")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { currentWallet.isPublic },
                            set: { _ in Task { await viewModel.toggleVisibility() } }
                        ))
                    }
                } header: {
                    Text("Visibility")
                }
            }

            // Transaction history
            Section {
                if viewModel.transactions.isEmpty {
                    Text("No transactions yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.transactions) { tx in
                        NavigationLink(destination: TransactionDetailView(transaction: tx)) {
                            TxHistoryRow(transaction: tx)
                        }
                    }
                }
            } header: {
                Text("Transactions")
            }
        }
    }
}

// MARK: - Transaction Row

struct TxHistoryRow: View {
    let transaction: TxHistoryEntry

    var body: some View {
        HStack {
            Image(systemName: transaction.direction == .received ? "arrow.down.left" : "arrow.up.right")
                .foregroundColor(transaction.direction == .received ? .green : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.formattedAmount)
                    .font(.body.weight(.medium))
                    .foregroundColor(transaction.direction == .received ? .green : .primary)
                if let date = transaction.blockDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !transaction.confirmed {
                    Text("Pending")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            if transaction.confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
    }
}
