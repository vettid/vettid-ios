import SwiftUI

/// Connection detail view
struct ConnectionDetailView: View {
    let connectionId: String
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: ConnectionDetailViewModel
    @State private var showRevokeConfirmation = false
    @State private var showShareSheet = false
    @State private var showRequestDataSheet = false
    @State private var showShareDataSheet = false
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, authTokenProvider: @escaping @Sendable () -> String?) {
        self.connectionId = connectionId
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: ConnectionDetailViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        ScrollView {
            if viewModel.isLoading {
                loadingView
            } else if let connection = viewModel.connection {
                connectionContent(connection)
            } else if let error = viewModel.errorMessage {
                errorView(error)
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Revoke Connection",
            isPresented: $showRevokeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                Task { await viewModel.revokeConnection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently end the connection. You won't be able to message each other.")
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil && !viewModel.isLoading)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task {
            await viewModel.loadConnection(connectionId)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showRequestDataSheet) {
            RequestDataSheet(
                connectionId: connectionId,
                peerName: viewModel.connection?.peerDisplayName ?? "Connection"
            )
        }
        .sheet(isPresented: $showShareDataSheet) {
            ShareDataSheet(
                connectionId: connectionId,
                peerName: viewModel.connection?.peerDisplayName ?? "Connection"
            )
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Connection Content

    private func connectionContent(_ connection: Connection) -> some View {
        VStack(spacing: 24) {
            // Avatar and name
            VStack(spacing: 12) {
                AsyncImage(url: URL(string: connection.peerAvatarUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundColor(.secondary)
                }
                .frame(width: 100, height: 100)
                .clipShape(Circle())

                Text(connection.peerDisplayName)
                    .font(.title)
                    .fontWeight(.bold)

                ConnectionStatusBadge(status: connection.status)
            }
            .padding(.top)

            // Profile info
            if let profile = viewModel.peerProfile {
                ProfileInfoSection(profile: profile)
            }

            // Shared data section
            SharedDataSection()

            // Connection info
            ConnectionInfoSection(connection: connection)

            // Actions
            if connection.status == .active {
                actionButtons
            }
        }
        .padding()
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Primary actions row
            HStack(spacing: 12) {
                NavigationLink(destination: ConversationView(
                    connectionId: connectionId,
                    authTokenProvider: authTokenProvider
                )) {
                    Label("Message", systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Secondary actions
            HStack(spacing: 12) {
                Button {
                    showRequestDataSheet = true
                } label: {
                    Label("Request Data", systemImage: "arrow.down.doc")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    showShareDataSheet = true
                } label: {
                    Label("Share Data", systemImage: "arrow.up.doc")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            // Danger zone
            Button(role: .destructive) {
                showRevokeConfirmation = true
            } label: {
                if viewModel.isRevoking {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Revoke Connection", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRevoking)
        }
    }

    // MARK: - Share Items

    private var shareItems: [Any] {
        guard let connection = viewModel.connection else { return [] }

        var items: [Any] = []

        // Basic connection info text
        let shareText = "Connected with \(connection.peerDisplayName) on VettID"
        items.append(shareText)

        // Connection deep link
        if let url = URL(string: "vettid://message/\(connection.id)") {
            items.append(url)
        }

        return items
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await viewModel.loadConnection(connectionId) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Profile Info Section

struct ProfileInfoSection: View {
    let profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let bio = profile.bio, !bio.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bio")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(bio)
                        .font(.body)
                }
            }

            if let location = profile.location, !location.isEmpty {
                HStack {
                    Image(systemName: "location")
                        .foregroundColor(.secondary)
                    Text(location)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Shared Data Section

struct SharedDataSection: View {
    // TODO: Load actual shared data from connection
    @State private var sharedItems: [SharedDataItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shared Data")
                    .font(.headline)
                Spacer()
                if !sharedItems.isEmpty {
                    Text("\(sharedItems.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if sharedItems.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No data shared yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ForEach(sharedItems) { item in
                    SharedDataItemRow(item: item)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct SharedDataItem: Identifiable {
    let id: String
    let type: SharedDataType
    let label: String
    let sharedAt: Date
    let direction: SharedDirection

    enum SharedDataType {
        case credential
        case document
        case profile
        case custom

        var icon: String {
            switch self {
            case .credential: return "key.fill"
            case .document: return "doc.fill"
            case .profile: return "person.fill"
            case .custom: return "cube.fill"
            }
        }

        var color: Color {
            switch self {
            case .credential: return .purple
            case .document: return .orange
            case .profile: return .blue
            case .custom: return .gray
            }
        }
    }

    enum SharedDirection {
        case sent
        case received
    }
}

struct SharedDataItemRow: View {
    let item: SharedDataItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.icon)
                .font(.body)
                .foregroundStyle(item.type.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.subheadline)
                HStack(spacing: 4) {
                    Image(systemName: item.direction == .sent ? "arrow.up.right" : "arrow.down.left")
                        .font(.caption2)
                    Text(item.direction == .sent ? "Sent" : "Received")
                        .font(.caption)
                    Text("·")
                    Text(item.sharedAt, style: .relative)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Connection Info Section

struct ConnectionInfoSection: View {
    let connection: Connection

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Connected since")
                    .foregroundColor(.secondary)
                Spacer()
                Text(connection.createdAt, style: .date)
            }
            .font(.subheadline)

            if let lastMessageAt = connection.lastMessageAt {
                Divider()
                HStack {
                    Text("Last message")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(lastMessageAt, style: .relative)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Share Sheet (UIKit)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Request Data Sheet

struct RequestDataSheet: View {
    let connectionId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDataTypes: Set<RequestableDataType> = []
    @State private var isRequesting = false
    @State private var requestSent = false

    enum RequestableDataType: String, CaseIterable, Identifiable {
        case email = "Email Address"
        case phone = "Phone Number"
        case name = "Full Name"
        case address = "Address"
        case organization = "Organization"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .email: return "envelope.fill"
            case .phone: return "phone.fill"
            case .name: return "person.fill"
            case .address: return "location.fill"
            case .organization: return "building.2.fill"
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if requestSent {
                    requestSentView
                } else {
                    requestFormView
                }
            }
            .navigationTitle("Request Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var requestFormView: some View {
        VStack(spacing: 20) {
            Text("Select the data you'd like to request from \(peerName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top)

            List {
                ForEach(RequestableDataType.allCases) { dataType in
                    Button {
                        if selectedDataTypes.contains(dataType) {
                            selectedDataTypes.remove(dataType)
                        } else {
                            selectedDataTypes.insert(dataType)
                        }
                    } label: {
                        HStack {
                            Image(systemName: dataType.icon)
                                .foregroundStyle(.blue)
                                .frame(width: 24)

                            Text(dataType.rawValue)
                                .foregroundStyle(.primary)

                            Spacer()

                            if selectedDataTypes.contains(dataType) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button {
                sendRequest()
            } label: {
                if isRequesting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Send Request")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedDataTypes.isEmpty || isRequesting)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var requestSentView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Request Sent")
                .font(.title2)
                .fontWeight(.bold)

            Text("\(peerName) will be notified of your data request.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private func sendRequest() {
        isRequesting = true

        // Simulate sending request via NATS/VaultResponseHandler
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                isRequesting = false
                requestSent = true
            }
        }
    }
}

// MARK: - Share Data Sheet

struct ShareDataSheet: View {
    let connectionId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDataFields: Set<ShareableDataField> = []
    @State private var isSharing = false
    @State private var dataSent = false

    enum ShareableDataField: String, CaseIterable, Identifiable {
        case displayName = "Display Name"
        case email = "Email Address"
        case phone = "Phone Number"
        case bio = "Bio"
        case location = "Location"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .displayName: return "person.fill"
            case .email: return "envelope.fill"
            case .phone: return "phone.fill"
            case .bio: return "text.quote"
            case .location: return "location.fill"
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if dataSent {
                    dataSentView
                } else {
                    shareFormView
                }
            }
            .navigationTitle("Share Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var shareFormView: some View {
        VStack(spacing: 20) {
            Text("Select the data you'd like to share with \(peerName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top)

            List {
                ForEach(ShareableDataField.allCases) { field in
                    Button {
                        if selectedDataFields.contains(field) {
                            selectedDataFields.remove(field)
                        } else {
                            selectedDataFields.insert(field)
                        }
                    } label: {
                        HStack {
                            Image(systemName: field.icon)
                                .foregroundStyle(.purple)
                                .frame(width: 24)

                            Text(field.rawValue)
                                .foregroundStyle(.primary)

                            Spacer()

                            if selectedDataFields.contains(field) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.purple)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button {
                shareData()
            } label: {
                if isSharing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Share Selected Data")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(selectedDataFields.isEmpty || isSharing)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var dataSentView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.purple)

            Text("Data Shared")
                .font(.title2)
                .fontWeight(.bold)

            Text("Your selected data has been shared with \(peerName).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .padding()
        }
    }

    private func shareData() {
        isSharing = true

        // Simulate sharing data via NATS/VaultResponseHandler
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                isSharing = false
                dataSent = true
            }
        }
    }
}

#if DEBUG
struct ConnectionDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ConnectionDetailView(
                connectionId: "test-id",
                authTokenProvider: { "test-token" }
            )
        }
    }
}
#endif
