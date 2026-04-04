import SwiftUI

struct CallHistoryView: View {

    @StateObject private var viewModel = CallHistoryViewModel()

    var callSignalingHandler: CallSignalingHandler?

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading call history...")
            case .empty:
                VStack(spacing: 12) {
                    Image(systemName: "phone.badge.waveform")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Call History")
                        .font(.headline)
                    Text("Your calls will appear here.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            case .loaded(let entries):
                List(entries) { entry in
                    CallHistoryRow(entry: entry)
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.refresh()
                }
            case .error(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(message)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task { await viewModel.loadHistory() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Call History")
        .task {
            viewModel.callSignalingHandler = callSignalingHandler
            await viewModel.loadHistory()
        }
    }
}

// MARK: - Call History Row

struct CallHistoryRow: View {
    let entry: CallHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            // Call type icon
            Image(systemName: entry.callType == .video ? "video.fill" : "phone.fill")
                .font(.body)
                .foregroundColor(entry.isMissed ? .red : .primary)
                .frame(width: 24)

            // Direction arrow
            Image(systemName: entry.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.caption)
                .foregroundColor(entry.isMissed ? .red : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.peerDisplayName ?? entry.peerGuid)
                    .font(.body.weight(.medium))
                    .foregroundColor(entry.isMissed ? .red : .primary)

                HStack(spacing: 4) {
                    Text(entry.endReason.displayText)
                        .font(.caption)
                        .foregroundColor(entry.isMissed ? .red : .secondary)

                    if let duration = entry.formattedDuration {
                        Text("(\(duration))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Text(entry.initiatedAt, style: .relative)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Display Text Extension

extension CallEndReason {
    var displayText: String {
        switch self {
        case .missed: return "Missed"
        case .rejected: return "Declined"
        case .busy: return "Busy"
        case .timeout: return "No Answer"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .completed: return "Completed"
        }
    }
}
