import SwiftUI

struct SendBtcView: View {

    var walletClient: WalletClient?
    var preselectedWallet: WalletInfo?

    @StateObject private var viewModel = SendBtcViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showSendConfirmation = false

    var body: some View {
        Group {
            switch viewModel.step {
            case .selectWallet:
                walletSelectionStep
            case .enterRecipient:
                recipientStep
            case .enterAmount:
                amountStep
            case .selectFee:
                feeStep
            case .review:
                reviewStep
            case .sending:
                sendingStep
            case .success(let result):
                successStep(result)
            case .error(let message):
                errorStep(message)
            }
        }
        .navigationTitle("Send Bitcoin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if showBackButton {
                    Button("Back") { viewModel.goBack() }
                }
            }
        }
        .alert("Confirm Send", isPresented: $showSendConfirmation) {
            Button("Send", role: .destructive) {
                Task { await viewModel.send() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Send \(viewModel.amountBtc) BTC to \(String(viewModel.recipientAddress.prefix(12)))...? This cannot be undone.")
        }
        .task {
            viewModel.walletClient = walletClient
            if let wallet = preselectedWallet {
                viewModel.selectedWallet = wallet
            }
            await viewModel.loadWallets()
            await viewModel.loadFeeEstimates()
        }
    }

    private var showBackButton: Bool {
        switch viewModel.step {
        case .enterAmount, .selectFee, .review: return true
        default: return false
        }
    }

    // MARK: - Steps

    private var walletSelectionStep: some View {
        List(viewModel.wallets) { wallet in
            Button(action: { viewModel.selectWallet(wallet) }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(wallet.label)
                            .font(.headline)
                        Text(wallet.formattedBalance)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if wallet.walletId == viewModel.selectedWallet?.walletId {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Select Wallet")
    }

    private var recipientStep: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Recipient Address")
                    .font(.headline)
                TextField("bc1q...", text: $viewModel.recipientAddress)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .padding(.horizontal)

            Button("Continue") {
                viewModel.proceedToAmount()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.recipientAddress.isEmpty)

            Spacer()
        }
    }

    private var amountStep: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Amount")
                    .font(.headline)
                TextField("0.00000000", text: $viewModel.amountBtc)
                    .font(.system(.title2, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)

                Text(viewModel.satsDisplay)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let wallet = viewModel.selectedWallet {
                    Text("Available: \(wallet.formattedBalance)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            Button("Continue") {
                viewModel.proceedToFee()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.amountSats <= 0)

            Spacer()
        }
    }

    private var feeStep: some View {
        VStack(spacing: 24) {
            Text("Fee Priority")
                .font(.headline)

            if let estimate = viewModel.feeEstimate {
                ForEach(FeeTier.allCases) { tier in
                    Button(action: { viewModel.selectedFeeTier = tier }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(tier.displayName)
                                    .font(.body.weight(.medium))
                                Text(tier.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(tier.rate(from: estimate)) sat/vB")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            if viewModel.selectedFeeTier == tier {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(viewModel.selectedFeeTier == tier ? Color.accentColor.opacity(0.1) : Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView("Loading fee estimates...")
            }

            Button("Review") {
                viewModel.proceedToReview()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canReview)

            Spacer()
        }
        .padding()
    }

    private var reviewStep: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 12) {
                reviewRow("To", value: viewModel.recipientAddress, monospaced: true)
                reviewRow("Amount", value: String(format: "%.8f BTC", Double(viewModel.amountSats) / 100_000_000.0))
                reviewRow("Fee Rate", value: "\(viewModel.selectedFeeRate ?? 0) sat/vB")
                if let wallet = viewModel.selectedWallet {
                    reviewRow("From", value: wallet.label)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            .padding(.horizontal)

            Button("Confirm & Send") {
                showSendConfirmation = true
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    private var sendingStep: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Signing and broadcasting...")
                .font(.headline)
            Text("This may take up to 60 seconds")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func successStep(_ result: TxResult) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Transaction Sent")
                .font(.title2.weight(.bold))

            VStack(spacing: 8) {
                Text("Transaction ID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(result.txid)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Copy TXID") {
                    SecurePasteboard.copySecure(result.txid, expiresIn: 30)
                }
                .font(.caption)
            }

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 40)
        }
    }

    private func errorStep(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                viewModel.reset()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private func reviewRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
