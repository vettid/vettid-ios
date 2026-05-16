import SwiftUI

struct CreateWalletSheet: View {

    var walletClient: WalletClient?
    var onCreated: (() -> Void)?

    @StateObject private var viewModel = CreateWalletViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Wallet name", text: $viewModel.label)
                } header: {
                    Text("Label")
                }

                Section {
                    Picker("Network", selection: $viewModel.network) {
                        ForEach(BitcoinNetwork.allCases, id: \.self) { network in
                            Text(network.displayName).tag(network)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Network")
                } footer: {
                    Text("Use Testnet for testing. Mainnet is for real Bitcoin.")
                }

                // Phase 5.2: password gate. The vault rotates the
                // credential CEK on every wallet.create, so the user
                // confirms with their password before the request
                // ships. Wipes from memory the moment the round-trip
                // completes (CreateWalletViewModel clears it).
                Section {
                    SecureField("Password", text: $viewModel.password)
                        .textContentType(.password)
                        .submitLabel(.done)
                } header: {
                    Text("Confirm with password")
                } footer: {
                    Text("Required — wallet creation rotates your credential, so the vault double-checks it's you.")
                }

                Section {
                    Label {
                        Text("Your private keys are generated and stored securely inside the vault enclave. They never leave the enclave.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.green)
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Create Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await viewModel.createWallet()
                            if viewModel.createdWallet != nil {
                                onCreated?()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!viewModel.canCreate)
                }
            }
            .overlay {
                if viewModel.isCreating {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                    ProgressView("Creating wallet...")
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
                }
            }
        }
        .task {
            viewModel.walletClient = walletClient
        }
        .presentationDetents([.medium])
    }
}
