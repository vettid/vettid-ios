import SwiftUI

struct TransactionDetailView: View {

    let transaction: TxHistoryEntry

    @State private var copiedTxid = false

    var body: some View {
        List {
            // Direction and amount
            Section {
                VStack(spacing: 12) {
                    Image(systemName: transaction.direction == .received ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(transaction.direction == .received ? .green : .orange)

                    Text(transaction.formattedAmount)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                        .foregroundColor(transaction.direction == .received ? .green : .primary)

                    Text(transaction.direction == .received ? "Received" : "Sent")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // Status
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    if transaction.confirmed {
                        Label("Confirmed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Pending", systemImage: "clock")
                            .foregroundColor(.orange)
                    }
                }

                if let blockHeight = transaction.blockHeight {
                    HStack {
                        Text("Block Height")
                        Spacer()
                        Text("\(blockHeight)")
                            .foregroundColor(.secondary)
                    }
                }

                if let date = transaction.blockDate {
                    HStack {
                        Text("Date")
                        Spacer()
                        Text(date, style: .date)
                            .foregroundColor(.secondary)
                        Text(date, style: .time)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Details")
            }

            // Fee
            Section {
                HStack {
                    Text("Fee")
                    Spacer()
                    Text("\(transaction.feeSats) sats")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Fee (BTC)")
                    Spacer()
                    Text(String(format: "%.8f", transaction.feeBtc))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Transaction ID
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(transaction.txid)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)

                    Button(action: copyTxid) {
                        Label(copiedTxid ? "Copied" : "Copy Transaction ID", systemImage: copiedTxid ? "checkmark" : "doc.on.doc")
                    }
                    .font(.caption)
                }
            } header: {
                Text("Transaction ID")
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copyTxid() {
        SecurePasteboard.copySecure(transaction.txid, expiresIn: 30)
        copiedTxid = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedTxid = false
        }
    }
}
