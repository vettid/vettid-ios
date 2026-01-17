import SwiftUI

/// View showing the user's vote history
struct MyVotesView: View {
    @StateObject private var viewModel = MyVotesViewModel()

    var body: some View {
        Group {
            if viewModel.votes.isEmpty {
                emptyView
            } else {
                votesList
            }
        }
        .navigationTitle("My Votes")
        .onAppear {
            viewModel.loadVotes()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.square")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Votes Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Your vote receipts will appear here after you vote on proposals.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var votesList: some View {
        List {
            ForEach(viewModel.groupedVotes.keys.sorted().reversed(), id: \.self) { month in
                Section(header: Text(month)) {
                    ForEach(viewModel.groupedVotes[month] ?? []) { receipt in
                        MyVoteRow(receipt: receipt)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            viewModel.loadVotes()
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MyVotesViewModel: ObservableObject {
    @Published private(set) var votes: [VoteReceipt] = []

    private let voteReceiptStore = VoteReceiptStore.shared

    var groupedVotes: [String: [VoteReceipt]] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        var groups: [String: [VoteReceipt]] = [:]
        for vote in votes {
            let key = formatter.string(from: vote.timestamp)
            groups[key, default: []].append(vote)
        }
        return groups
    }

    func loadVotes() {
        votes = voteReceiptStore.retrieveAll().sorted { $0.timestamp > $1.timestamp }
    }
}

// MARK: - My Vote Row

struct MyVoteRow: View {
    let receipt: VoteReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(receipt.proposalNumber)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                verificationBadge
            }

            Text(receipt.proposalTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)

            HStack {
                Label(receipt.choice.displayName, systemImage: receipt.choice.systemImage)
                    .font(.caption)
                    .foregroundColor(choiceColor)

                Spacer()

                Text(receipt.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var verificationBadge: some View {
        if receipt.isVerified == true {
            Label("Verified", systemImage: "checkmark.seal.fill")
                .font(.caption2)
                .foregroundColor(.green)
        } else {
            Label("Pending", systemImage: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var choiceColor: Color {
        switch receipt.choice {
        case .yes: return .green
        case .no: return .red
        case .abstain: return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MyVotesView()
    }
}
