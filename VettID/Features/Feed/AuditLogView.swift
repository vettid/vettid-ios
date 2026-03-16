import SwiftUI

// MARK: - Feed Audit Log View

struct FeedAuditLogView: View {
    @StateObject private var viewModel: FeedAuditLogViewModel
    @State private var showingEventTypeFilter = false
    @State private var showingExportSheet = false

    init(feedClient: FeedClient? = nil) {
        self._viewModel = StateObject(wrappedValue: FeedAuditLogViewModel(feedClient: feedClient))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Time window picker
            timeWindowPicker

            // Search and filter bar
            searchAndFilterBar

            // Content
            if viewModel.isLoading && viewModel.events.isEmpty {
                loadingView
            } else if viewModel.filteredEvents.isEmpty {
                emptyView
            } else {
                auditEventsList
            }
        }
        .navigationTitle("Audit Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Verify Integrity
                    Button {
                        viewModel.verifyIntegrity()
                    } label: {
                        Label("Verify Integrity", systemImage: "checkmark.shield")
                    }

                    Divider()

                    // Export options
                    Button {
                        showingExportSheet = true
                    } label: {
                        Label("Export...", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    // Refresh
                    Button {
                        Task { await viewModel.loadAudit() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await viewModel.loadAudit()
        }
        .onChange(of: viewModel.selectedTimeWindow) { _ in
            Task { await viewModel.loadAudit() }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            AuditExportSheet(viewModel: viewModel)
        }
    }

    // MARK: - Time Window Picker

    private var timeWindowPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AuditTimeWindow.allCases, id: \.self) { window in
                    Button {
                        viewModel.selectedTimeWindow = window
                    } label: {
                        Text(window.displayName)
                            .font(.subheadline)
                            .fontWeight(viewModel.selectedTimeWindow == window ? .semibold : .regular)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                viewModel.selectedTimeWindow == window
                                    ? Color.blue
                                    : Color(.systemGray6)
                            )
                            .foregroundStyle(viewModel.selectedTimeWindow == window ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Search and Filter Bar

    private var searchAndFilterBar: some View {
        VStack(spacing: 8) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search audit events...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(10)

            // Event type filter
            HStack(spacing: 8) {
                // Event type dropdown
                Button {
                    showingEventTypeFilter = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.caption)
                        Text(viewModel.selectedEventType ?? "All Types")
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        viewModel.selectedEventType != nil
                            ? Color.blue
                            : Color(.systemGray6)
                    )
                    .foregroundStyle(viewModel.selectedEventType != nil ? .white : .primary)
                    .cornerRadius(16)
                }
                .confirmationDialog("Filter by Event Type", isPresented: $showingEventTypeFilter) {
                    Button("All Types") {
                        viewModel.selectedEventType = nil
                    }
                    ForEach(viewModel.availableEventTypes, id: \.self) { eventType in
                        Button(formatEventType(eventType)) {
                            viewModel.selectedEventType = eventType
                        }
                    }
                }

                // Integrity status badge
                if let verified = viewModel.integrityVerified {
                    integrityBadge(verified: verified)
                }

                Spacer()

                // Event count
                Text("\(viewModel.filteredEvents.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Clear filters
                if viewModel.hasActiveFilters {
                    Button("Clear") {
                        viewModel.clearFilters()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Integrity Badge

    private func integrityBadge(verified: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: verified ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.caption2)
            Text(verified ? "Verified" : "Warning")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(verified ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
        .foregroundStyle(verified ? .green : .red)
        .cornerRadius(8)
    }

    // MARK: - Audit Events List

    private var auditEventsList: some View {
        List {
            ForEach(viewModel.filteredEvents) { event in
                AuditEventRow(event: event)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.loadAudit()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("Loading audit log...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("No Audit Events")
                .font(.title3)
                .fontWeight(.semibold)

            if viewModel.hasActiveFilters {
                Text("Try adjusting your filters or search query.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button("Clear Filters") {
                    viewModel.clearFilters()
                }
                .buttonStyle(.bordered)
            } else {
                Text("Audit events will appear here as activity occurs in your vault.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func formatEventType(_ eventType: String) -> String {
        eventType
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

// MARK: - Audit Event Row

struct AuditEventRow: View {
    let event: VaultFeedEvent
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row
            HStack(spacing: 12) {
                // Event type icon
                eventTypeIcon

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(event.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Spacer()

                        // Priority indicator
                        if event.priorityLevel != .normal {
                            priorityBadge
                        }
                    }

                    if let message = event.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                    }

                    // Bottom row: timestamp and sync sequence
                    HStack(spacing: 12) {
                        // Timestamp
                        Text(event.createdDate, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Spacer()

                        // Sync sequence badge
                        syncSequenceBadge
                    }
                }

                // Unread indicator
                if event.isUnread {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                }
            }

            // Expanded details
            if isExpanded {
                expandedDetails
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    // MARK: - Event Type Icon

    private var eventTypeIcon: some View {
        ZStack {
            Circle()
                .fill(eventColor.opacity(0.15))
                .frame(width: 40, height: 40)

            Image(systemName: eventIcon)
                .font(.system(size: 16))
                .foregroundStyle(eventColor)
        }
    }

    private var eventIcon: String {
        let type = event.eventType.lowercased()
        if type.contains("auth") || type.contains("login") {
            return "person.badge.key.fill"
        } else if type.contains("credential") {
            return "checkmark.seal.fill"
        } else if type.contains("data") || type.contains("share") {
            return "arrow.right.arrow.left.circle.fill"
        } else if type.contains("connection") {
            return "person.2.fill"
        } else if type.contains("backup") {
            return "externaldrive.fill"
        } else if type.contains("security") || type.contains("alert") {
            return "exclamationmark.shield.fill"
        } else if type.contains("payment") {
            return "creditcard.fill"
        } else if type.contains("message") {
            return "message.fill"
        } else if type.contains("vault") {
            return "lock.shield.fill"
        } else {
            return "doc.text.fill"
        }
    }

    private var eventColor: Color {
        let type = event.eventType.lowercased()
        if type.contains("security") || type.contains("alert") {
            return .red
        } else if type.contains("auth") || type.contains("login") {
            return .purple
        } else if type.contains("credential") {
            return .green
        } else if type.contains("data") || type.contains("share") {
            return .blue
        } else if type.contains("connection") {
            return .teal
        } else if type.contains("backup") {
            return .indigo
        } else if type.contains("payment") {
            return .orange
        } else {
            return .secondary
        }
    }

    // MARK: - Priority Badge

    private var priorityBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: event.priorityLevel.icon)
                .font(.caption2)
            Text(event.priorityLevel.displayName)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(event.priorityLevel.color.opacity(0.15))
        .foregroundStyle(event.priorityLevel.color)
        .cornerRadius(4)
    }

    // MARK: - Sync Sequence Badge

    private var syncSequenceBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "number")
                .font(.system(size: 8))
            Text("\(event.syncSequence)")
                .font(.caption2)
                .monospacedDigit()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(.systemGray6))
        .cornerRadius(4)
    }

    // MARK: - Expanded Details

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            detailRow(label: "Event ID", value: event.eventId)
            detailRow(label: "Event Type", value: event.eventType)
            detailRow(label: "Source", value: "\(event.sourceType ?? "unknown"): \(event.sourceId ?? "unknown")")
            detailRow(label: "Status", value: event.feedStatus.capitalized)
            detailRow(label: "Priority", value: event.priorityLevel.displayName)

            if let actionType = event.actionType, !actionType.isEmpty {
                detailRow(label: "Action", value: actionType)
            }

            detailRow(label: "Retention", value: event.retentionClass.capitalized)

            // Metadata
            if let metadata = event.metadata, !metadata.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium)

                    ForEach(metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top) {
                            Text(key)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(width: 80, alignment: .leading)
                            Text(value)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }

            // Timestamps
            VStack(alignment: .leading, spacing: 2) {
                Text("Timestamps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontWeight(.medium)

                detailRow(label: "Created", value: formatTimestamp(event.createdAt))

                if let readAt = event.readAt {
                    detailRow(label: "Read", value: formatTimestamp(readAt))
                }

                if let actionedAt = event.actionedAt {
                    detailRow(label: "Actioned", value: formatTimestamp(actionedAt))
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 4)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func formatTimestamp(_ epochMillis: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: epochMillis / 1000.0)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Audit Export Sheet

struct AuditExportSheet: View {
    @ObservedObject var viewModel: FeedAuditLogViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormat: AuditExportFormat = .json

    var body: some View {
        NavigationStack {
            Form {
                Section("Export Format") {
                    Picker("Format", selection: $selectedFormat) {
                        ForEach(AuditExportFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Summary") {
                    HStack {
                        Text("Events to export")
                        Spacer()
                        Text("\(viewModel.filteredEvents.count)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Time window")
                        Spacer()
                        Text(viewModel.selectedTimeWindow.displayName)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.hasActiveFilters {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease")
                                .foregroundStyle(.secondary)
                            Text("Filters applied")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    let exportContent = selectedFormat == .json
                        ? viewModel.exportJSON()
                        : viewModel.exportCSV()

                    ShareLink(
                        item: exportContent,
                        subject: Text("VettID Audit Log"),
                        message: Text("Audit log export (\(viewModel.filteredEvents.count) events)")
                    ) {
                        HStack {
                            Spacer()
                            Label("Share \(selectedFormat.displayName)", systemImage: "square.and.arrow.up")
                            Spacer()
                        }
                    }

                    Button {
                        UIPasteboard.general.string = exportContent
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Export Audit Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Audit Export Format

enum AuditExportFormat: String, CaseIterable {
    case json
    case csv

    var displayName: String {
        rawValue.uppercased()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FeedAuditLogView()
    }
}
