import SwiftUI

struct WalletListView: View {

    @StateObject private var viewModel = WalletListViewModel()

    /// Injected wallet client from parent
    var walletClient: WalletClient?

    @State private var showCreateSheet = false

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading wallets...")
            case .empty:
                emptyView
            case .loaded(let wallets):
                walletList(wallets)
            case .error(let message):
                errorView(message)
            }

            // Floating action button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { showCreateSheet = true }) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .shadow(radius: 4, y: 2)
                    }
                    .accessibilityLabel("Create new wallet")
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .task {
            viewModel.walletClient = walletClient
            await viewModel.loadWallets()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateWalletSheet(walletClient: walletClient) {
                Task { await viewModel.refresh() }
            }
        }
    }

    // MARK: - Subviews

    private func walletList(_ wallets: [WalletInfo]) -> some View {
        List(wallets) { wallet in
            NavigationLink(destination: WalletDetailView(wallet: wallet, walletClient: walletClient)) {
                WalletCard(wallet: wallet)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bitcoinsign.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("No Wallets")
                .font(.title2.weight(.semibold))
            Text("Create your first wallet to send and receive Bitcoin.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Create Wallet") {
                showCreateSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadWallets() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

// MARK: - Wallet Card

struct WalletCard: View {
    let wallet: WalletInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(wallet.label)
                    .font(.headline)
                Spacer()
                Text(wallet.network.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(wallet.network == .mainnet ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                    .foregroundColor(wallet.network == .mainnet ? .orange : .blue)
                    .cornerRadius(4)
            }

            Text(wallet.truncatedAddress)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            HStack {
                Text(wallet.formattedBalance)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if wallet.isPublic {
                    Label("Public", systemImage: "eye")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
