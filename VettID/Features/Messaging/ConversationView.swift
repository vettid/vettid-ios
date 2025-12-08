import SwiftUI

/// Conversation/messaging view
struct ConversationView: View {
    let connectionId: String
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: ConversationViewModel
    @State private var messageText = ""
    @FocusState private var isInputFocused: Bool

    init(connectionId: String, authTokenProvider: @escaping @Sendable () -> String?) {
        self.connectionId = connectionId
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: ConversationViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage, viewModel.messages.isEmpty {
                errorView(error)
            } else {
                messagesView
            }

            Divider()

            MessageInputView(
                text: $messageText,
                isFocused: $isInputFocused,
                isSending: viewModel.isSending,
                onSend: sendMessage
            )
        }
        .navigationTitle(viewModel.connectionName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: ConnectionDetailView(
                    connectionId: connectionId,
                    authTokenProvider: authTokenProvider
                )) {
                    Image(systemName: "info.circle")
                }
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil && !viewModel.messages.isEmpty)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task {
            viewModel.connectionId = connectionId
            await viewModel.loadMessages()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading messages...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Messages View

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Load more button
                    if viewModel.hasMoreMessages {
                        Button("Load earlier messages") {
                            Task { await viewModel.loadMoreMessages() }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                    }

                    ForEach(viewModel.groupedMessages, id: \.id) { group in
                        DateDivider(date: group.date)

                        ForEach(group.messages) { message in
                            MessageBubble(
                                message: message,
                                isSent: message.senderId == viewModel.currentUserId
                            )
                            .id(message.id)
                            .onAppear {
                                // Mark as read when visible
                                if message.senderId != viewModel.currentUserId && message.readAt == nil {
                                    Task { await viewModel.markAsRead(message.id) }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let lastMessage = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.loadMessages() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = messageText
        messageText = ""
        Task {
            await viewModel.sendMessage(text)
        }
    }
}

// MARK: - Date Divider

struct DateDivider: View {
    let date: Date

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(formattedDate)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
            VStack { Divider() }
        }
        .padding(.vertical, 8)
    }

    private var formattedDate: String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    let isSent: Bool

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 60) }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isSent ? Color.blue : Color(.systemGray5))
                    .foregroundColor(isSent ? .white : .primary)
                    .cornerRadius(16)

                HStack(spacing: 4) {
                    Text(message.sentAt, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if isSent {
                        MessageStatusIcon(status: message.status)
                    }
                }
            }

            if !isSent { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Message Status Icon

struct MessageStatusIcon: View {
    let status: MessageStatus

    var body: some View {
        Group {
            switch status {
            case .sending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .delivered:
                Image(systemName: "checkmark.circle")
            case .read:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.circle")
            }
        }
        .font(.caption2)
        .foregroundColor(statusColor)
    }

    private var statusColor: Color {
        switch status {
        case .sending:
            return .secondary
        case .sent, .delivered:
            return .secondary
        case .read:
            return .blue
        case .failed:
            return .red
        }
    }
}

// MARK: - Message Input View

struct MessageInputView: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused(isFocused)

            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(canSend ? .blue : .secondary)
                }
            }
            .disabled(!canSend || isSending)
        }
        .padding()
        .background(Color(.systemBackground))
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#if DEBUG
struct ConversationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ConversationView(
                connectionId: "test-id",
                authTokenProvider: { "test-token" }
            )
        }
    }
}
#endif
