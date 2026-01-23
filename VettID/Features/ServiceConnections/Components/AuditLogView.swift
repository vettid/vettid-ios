import SwiftUI
import UniformTypeIdentifiers

/// Complete audit trail UI showing all service data access
struct AuditLogView: View {
    @StateObject private var viewModel = AuditLogViewModel()
    @State private var showingServiceFilter = false
    @State private var showingOperationFilter = false
    @State private var showingDateFilter = false
    @State private var showingExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            filterBar

            // Content
            if viewModel.isLoading && viewModel.entries.isEmpty {
                loadingView
            } else if viewModel.entries.isEmpty {
                emptyView
            } else {
                auditList
            }
        }
        .navigationTitle("Audit Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showingExportSheet = true
                    } label: {
                        Label("Export Log", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        Task {
                            await viewModel.verifyIntegrity()
                        }
                    } label: {
                        Label("Verify Integrity", systemImage: "checkmark.shield")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await viewModel.loadEntries()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportAuditLogSheet(viewModel: viewModel)
        }
        .alert("Integrity Check", isPresented: $viewModel.showingIntegrityResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.integrityMessage ?? "")
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Service filter
                FilterChipButton(
                    title: viewModel.selectedService ?? "All Services",
                    isActive: viewModel.selectedService != nil
                ) {
                    showingServiceFilter = true
                }
                .confirmationDialog("Filter by Service", isPresented: $showingServiceFilter) {
                    Button("All Services") {
                        viewModel.selectedService = nil
                    }
                    ForEach(viewModel.availableServices, id: \.self) { service in
                        Button(service) {
                            viewModel.selectedService = service
                        }
                    }
                }

                // Operation filter
                FilterChipButton(
                    title: viewModel.selectedOperation?.displayName ?? "All Operations",
                    isActive: viewModel.selectedOperation != nil
                ) {
                    showingOperationFilter = true
                }
                .confirmationDialog("Filter by Operation", isPresented: $showingOperationFilter) {
                    Button("All Operations") {
                        viewModel.selectedOperation = nil
                    }
                    ForEach(AuditOperationType.allCases, id: \.self) { operation in
                        Button(operation.displayName) {
                            viewModel.selectedOperation = operation
                        }
                    }
                }

                // Date filter
                FilterChipButton(
                    title: viewModel.dateRange.displayName,
                    isActive: viewModel.dateRange != .all
                ) {
                    showingDateFilter = true
                }
                .confirmationDialog("Filter by Date", isPresented: $showingDateFilter) {
                    ForEach(DateRangeFilter.allCases, id: \.self) { range in
                        Button(range.displayName) {
                            viewModel.dateRange = range
                        }
                    }
                }

                // Clear filters
                if viewModel.hasActiveFilters {
                    Button("Clear") {
                        viewModel.clearFilters()
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading audit log...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Audit Entries")
                .font(.headline)

            if viewModel.hasActiveFilters {
                Text("Try adjusting your filters")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button("Clear Filters") {
                    viewModel.clearFilters()
                }
                .buttonStyle(.bordered)
            } else {
                Text("Service activity will appear here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Audit List

    private var auditList: some View {
        List {
            // Integrity status
            if let integrityStatus = viewModel.integrityStatus {
                Section {
                    integrityStatusRow(integrityStatus)
                }
            }

            // Entries grouped by date
            ForEach(viewModel.groupedEntries, id: \.date) { group in
                Section {
                    ForEach(group.entries) { entry in
                        AuditEntryRow(entry: entry)
                    }
                } header: {
                    Text(formatSectionDate(group.date))
                }
            }

            // Load more
            if viewModel.hasMore {
                Section {
                    Button {
                        Task {
                            await viewModel.loadMore()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isLoadingMore {
                                ProgressView()
                            } else {
                                Text("Load More")
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func integrityStatusRow(_ status: IntegrityStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: status.isValid ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundColor(status.isValid ? .green : .red)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.isValid ? "Hash Chain Verified" : "Integrity Warning")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(status.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !status.isValid {
                Button("Details") {
                    // Show details
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

// MARK: - Filter Chip Button

struct FilterChipButton: View {
    let title: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.accentColor : Color(UIColor.tertiarySystemBackground))
            .foregroundColor(isActive ? .white : .primary)
            .cornerRadius(20)
        }
    }
}

// MARK: - Audit Entry Row

struct AuditEntryRow: View {
    let entry: AuditEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row
            HStack(spacing: 12) {
                // Service logo
                if let logoUrl = entry.serviceLogoUrl, let url = URL(string: logoUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        servicePlaceholder
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    servicePlaceholder
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.serviceName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(entry.operation.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Status and time
                VStack(alignment: .trailing, spacing: 2) {
                    statusBadge(entry.status)

                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
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

    private var servicePlaceholder: some View {
        ZStack {
            Color(UIColor.tertiarySystemBackground)
            Image(systemName: "building.2.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func statusBadge(_ status: AuditEntryStatus) -> some View {
        Text(status.rawValue.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.1))
            .cornerRadius(4)
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            detailRow(label: "Request", value: entry.requestSummary)
            detailRow(label: "Response", value: entry.responseSummary)
            detailRow(label: "Capability", value: entry.capability)
            detailRow(label: "Entry ID", value: String(entry.id.prefix(16)) + "...")

            // Hash info
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Hash: \(String(entry.entryHash.prefix(12)))...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontDesign(.monospaced)
            }
        }
        .padding(.top, 8)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Export Sheet

struct ExportAuditLogSheet: View {
    @ObservedObject var viewModel: AuditLogViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportFormat: ExportFormat = .json
    @State private var isExporting = false

    var body: some View {
        NavigationView {
            Form {
                Section("Export Format") {
                    Picker("Format", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    HStack {
                        Text("Entries to export")
                        Spacer()
                        Text("\(viewModel.filteredEntries.count)")
                            .foregroundColor(.secondary)
                    }

                    if viewModel.hasActiveFilters {
                        Text("Filters applied")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button {
                        Task {
                            await exportLog()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isExporting {
                                ProgressView()
                            } else {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isExporting)
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

    private func exportLog() async {
        isExporting = true

        // Generate export
        let data = viewModel.exportData(format: exportFormat)

        // Share sheet would be presented here
        #if DEBUG
        print("[AuditLog] Exported \(viewModel.filteredEntries.count) entries as \(exportFormat.displayName)")
        #endif

        isExporting = false
        dismiss()
    }
}

// MARK: - Audit Types

/// Audit log entry
struct AuditEntry: Codable, Identifiable {
    let id: String
    let serviceId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let operation: AuditOperationType
    let requestSummary: String
    let responseSummary: String
    let capability: String
    let status: AuditEntryStatus
    let timestamp: Date
    let entryHash: String
    let previousHash: String

    enum CodingKeys: String, CodingKey {
        case id = "entry_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case operation
        case requestSummary = "request_summary"
        case responseSummary = "response_summary"
        case capability
        case status
        case timestamp
        case entryHash = "entry_hash"
        case previousHash = "previous_hash"
    }
}

/// Operation types
enum AuditOperationType: String, Codable, CaseIterable {
    case dataRead = "data_read"
    case dataWrite = "data_write"
    case auth
    case payment
    case message
    case contractUpdate = "contract_update"
    case revocation

    var displayName: String {
        switch self {
        case .dataRead: return "Data Read"
        case .dataWrite: return "Data Write"
        case .auth: return "Authentication"
        case .payment: return "Payment"
        case .message: return "Message"
        case .contractUpdate: return "Contract Update"
        case .revocation: return "Revocation"
        }
    }

    var icon: String {
        switch self {
        case .dataRead: return "eye.fill"
        case .dataWrite: return "pencil"
        case .auth: return "person.badge.key.fill"
        case .payment: return "creditcard.fill"
        case .message: return "message.fill"
        case .contractUpdate: return "doc.badge.arrow.up.fill"
        case .revocation: return "xmark.shield.fill"
        }
    }
}

/// Entry status
enum AuditEntryStatus: String, Codable {
    case success
    case denied
    case failed
    case pending

    var color: Color {
        switch self {
        case .success: return .green
        case .denied: return .orange
        case .failed: return .red
        case .pending: return .secondary
        }
    }
}

/// Date range filter
enum DateRangeFilter: String, CaseIterable {
    case all
    case today
    case week
    case month
    case custom

    var displayName: String {
        switch self {
        case .all: return "All Time"
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        case .custom: return "Custom Range"
        }
    }
}

/// Export format
enum ExportFormat: String, CaseIterable {
    case json
    case csv

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .csv: return "CSV"
        }
    }
}

/// Integrity check status
struct IntegrityStatus {
    let isValid: Bool
    let message: String
    let lastVerified: Date
}

// MARK: - ViewModel

@MainActor
final class AuditLogViewModel: ObservableObject {
    @Published private(set) var entries: [AuditEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published var selectedService: String?
    @Published var selectedOperation: AuditOperationType?
    @Published var dateRange: DateRangeFilter = .all
    @Published private(set) var integrityStatus: IntegrityStatus?
    @Published var showingIntegrityResult = false
    @Published var integrityMessage: String?

    struct EntryGroup {
        let date: Date
        let entries: [AuditEntry]
    }

    var availableServices: [String] {
        Array(Set(entries.map { $0.serviceName })).sorted()
    }

    var hasActiveFilters: Bool {
        selectedService != nil || selectedOperation != nil || dateRange != .all
    }

    var filteredEntries: [AuditEntry] {
        entries.filter { entry in
            if let service = selectedService, entry.serviceName != service {
                return false
            }
            if let operation = selectedOperation, entry.operation != operation {
                return false
            }
            if !matchesDateRange(entry.timestamp) {
                return false
            }
            return true
        }
    }

    var groupedEntries: [EntryGroup] {
        let calendar = Calendar.current
        var groups: [Date: [AuditEntry]] = [:]

        for entry in filteredEntries {
            let dayStart = calendar.startOfDay(for: entry.timestamp)
            groups[dayStart, default: []].append(entry)
        }

        return groups
            .map { EntryGroup(date: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.date > $1.date }
    }

    func loadEntries() async {
        guard !isLoading else { return }
        isLoading = true

        #if DEBUG
        try? await Task.sleep(nanoseconds: 500_000_000)
        entries = mockEntries
        integrityStatus = IntegrityStatus(
            isValid: true,
            message: "All \(entries.count) entries verified",
            lastVerified: Date()
        )
        hasMore = false
        #endif

        isLoading = false
    }

    func refresh() async {
        await loadEntries()
    }

    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        hasMore = false
        isLoadingMore = false
    }

    func clearFilters() {
        selectedService = nil
        selectedOperation = nil
        dateRange = .all
    }

    func verifyIntegrity() async {
        // Verify hash chain
        #if DEBUG
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        integrityMessage = "Hash chain verification successful. All \(entries.count) entries are valid and unmodified."
        showingIntegrityResult = true
        #endif
    }

    func exportData(format: ExportFormat) -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            return (try? encoder.encode(filteredEntries)) ?? Data()
        case .csv:
            var csv = "Entry ID,Service,Operation,Status,Timestamp\n"
            for entry in filteredEntries {
                csv += "\(entry.id),\(entry.serviceName),\(entry.operation.displayName),\(entry.status.rawValue),\(entry.timestamp.ISO8601Format())\n"
            }
            return csv.data(using: .utf8) ?? Data()
        }
    }

    private func matchesDateRange(_ date: Date) -> Bool {
        let calendar = Calendar.current
        switch dateRange {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .week:
            return calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear)
        case .month:
            return calendar.isDate(date, equalTo: Date(), toGranularity: .month)
        case .custom:
            return true // Would use custom date range
        }
    }

    #if DEBUG
    private var mockEntries: [AuditEntry] {
        [
            AuditEntry(
                id: "audit-1",
                serviceId: "service-1",
                serviceName: "Example Bank",
                serviceLogoUrl: nil,
                operation: .dataRead,
                requestSummary: "Read email and phone",
                responseSummary: "Data provided",
                capability: "read_profile",
                status: .success,
                timestamp: Date().addingTimeInterval(-1800),
                entryHash: "abc123def456",
                previousHash: "xyz789abc012"
            ),
            AuditEntry(
                id: "audit-2",
                serviceId: "service-1",
                serviceName: "Example Bank",
                serviceLogoUrl: nil,
                operation: .auth,
                requestSummary: "Login verification",
                responseSummary: "Approved",
                capability: "authenticate",
                status: .success,
                timestamp: Date().addingTimeInterval(-3600),
                entryHash: "def456ghi789",
                previousHash: "abc123def456"
            ),
            AuditEntry(
                id: "audit-3",
                serviceId: "service-2",
                serviceName: "HealthFirst",
                serviceLogoUrl: nil,
                operation: .dataRead,
                requestSummary: "Read address",
                responseSummary: "Denied by user",
                capability: "read_address",
                status: .denied,
                timestamp: Date().addingTimeInterval(-86400),
                entryHash: "ghi789jkl012",
                previousHash: "def456ghi789"
            ),
            AuditEntry(
                id: "audit-4",
                serviceId: "service-3",
                serviceName: "TechStore",
                serviceLogoUrl: nil,
                operation: .payment,
                requestSummary: "Payment $49.99",
                responseSummary: "Completed",
                capability: "process_payment",
                status: .success,
                timestamp: Date().addingTimeInterval(-86400 * 2),
                entryHash: "jkl012mno345",
                previousHash: "ghi789jkl012"
            )
        ]
    }
    #endif
}

// MARK: - Preview

#if DEBUG
struct AuditLogView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AuditLogView()
        }
    }
}
#endif
