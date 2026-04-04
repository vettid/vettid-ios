import Foundation

@MainActor
final class CallHistoryViewModel: ObservableObject {

    enum State {
        case loading
        case empty
        case loaded([CallHistoryEntry])
        case error(String)
    }

    @Published var state: State = .loading

    var callSignalingHandler: CallSignalingHandler?

    func loadHistory() async {
        state = .loading
        do {
            guard let handler = callSignalingHandler else {
                state = .error("Call service unavailable")
                return
            }
            let entries = try await handler.getCallHistory(limit: 50)
            let sorted = entries.sorted { $0.initiatedAt > $1.initiatedAt }
            if sorted.isEmpty {
                state = .empty
            } else {
                state = .loaded(sorted)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func refresh() async {
        guard let handler = callSignalingHandler else { return }
        do {
            let entries = try await handler.getCallHistory(limit: 50)
            let sorted = entries.sorted { $0.initiatedAt > $1.initiatedAt }
            state = sorted.isEmpty ? .empty : .loaded(sorted)
        } catch {
            #if DEBUG
            print("[CallHistoryVM] Refresh failed: \(error)")
            #endif
        }
    }
}
