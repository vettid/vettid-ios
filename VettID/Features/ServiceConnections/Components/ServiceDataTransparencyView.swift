import SwiftUI
import UIKit

/// View for data transparency - view, delete, and export service data
struct ServiceDataTransparencyView: View {
    @StateObject private var viewModel: ServiceDataTransparencyViewModel
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, serviceConnectionHandler: ServiceConnectionHandler) {
        self._viewModel = StateObject(wrappedValue: ServiceDataTransparencyViewModel(
            connectionId: connectionId,
            serviceConnectionHandler: serviceConnectionHandler
        ))
    }

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading && viewModel.dataRecords.isEmpty {
                    ProgressView()
                } else {
                    content
                }
            }
            .navigationTitle("Your Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            Task { await viewModel.exportAllData() }
                        } label: {
                            Label("Export All Data", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            viewModel.showingDeleteAllConfirmation = true
                        } label: {
                            Label("Delete All Data", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Delete All Data?", isPresented: $viewModel.showingDeleteAllConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete All", role: .destructive) {
                    Task { await viewModel.deleteAllData() }
                }
            } message: {
                Text("This will permanently delete all data this service has stored about you. This action cannot be undone.")
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.clearError() }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
            .sheet(isPresented: $viewModel.showingExportSheet) {
                if let exportURL = viewModel.exportURL {
                    ServiceDataShareSheet(items: [exportURL])
                }
            }
            .task {
                await viewModel.loadData()
            }
        }
    }

    private var content: some View {
        List {
            // Storage Summary
            Section {
                DataStorageSummaryCard(summary: viewModel.summary)
            }

            // Data Records
            if !viewModel.dataRecords.isEmpty {
                Section(header: Text("Stored Data")) {
                    ForEach(viewModel.dataRecords) { record in
                        DataRecordRow(record: record) {
                            Task { await viewModel.deleteRecord(record) }
                        }
                    }
                }
            }

            // Empty State
            if viewModel.dataRecords.isEmpty && viewModel.summary?.totalItems == 0 {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)

                        Text("No Data Stored")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("This service hasn't stored any data about you yet")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refresh()
        }
    }
}

// MARK: - Storage Summary Card

struct DataStorageSummaryCard: View {
    let summary: ServiceDataSummary?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Storage Usage")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }

            if let summary = summary {
                HStack {
                    Text(formattedSize(summary.totalSizeBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(summary.totalItems) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Category breakdown
                if !summary.categories.isEmpty {
                    Divider()

                    ForEach(summary.categories.sorted(by: { $0.value > $1.value }), id: \.key) { category, count in
                        HStack {
                            Text(category)
                                .font(.caption)
                            Spacer()
                            Text("\(count) items")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Data Record Row

struct DataRecordRow: View {
    let record: ServiceStorageRecord
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconForCategory(record.category))
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.label ?? record.id)
                    .font(.subheadline)

                HStack(spacing: 8) {
                    Text(record.createdAt, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(record.category)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete Item?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("This will permanently delete this data item. This action cannot be undone.")
        }
    }

    private func iconForCategory(_ category: String) -> String {
        switch category.lowercased() {
        case "profile": return "person.fill"
        case "document": return "doc.fill"
        case "credential": return "person.badge.key.fill"
        case "transaction": return "creditcard.fill"
        case "preference": return "slider.horizontal.3"
        default: return "doc.text.fill"
        }
    }
}

// MARK: - Share Sheet

struct ServiceDataShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Data Transparency ViewModel

@MainActor
final class ServiceDataTransparencyViewModel: ObservableObject {
    @Published private(set) var dataRecords: [ServiceStorageRecord] = []
    @Published private(set) var summary: ServiceDataSummary?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var showingDeleteAllConfirmation = false
    @Published var showingExportSheet = false
    @Published var exportURL: URL?

    private let connectionId: String
    private let serviceConnectionHandler: ServiceConnectionHandler

    init(connectionId: String, serviceConnectionHandler: ServiceConnectionHandler) {
        self.connectionId = connectionId
        self.serviceConnectionHandler = serviceConnectionHandler
    }

    func loadData() async {
        guard !isLoading else { return }
        isLoading = true

        do {
            async let summaryTask = serviceConnectionHandler.getDataSummary(connectionId: connectionId)
            async let recordsTask = serviceConnectionHandler.listStoredData(connectionId: connectionId)

            summary = try await summaryTask
            dataRecords = try await recordsTask
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func refresh() async {
        await loadData()
    }

    func deleteRecord(_ record: ServiceStorageRecord) async {
        do {
            _ = try await serviceConnectionHandler.deleteData(connectionId: connectionId, keys: [record.id])
            dataRecords.removeAll { $0.id == record.id }
            // Refresh summary
            summary = try? await serviceConnectionHandler.getDataSummary(connectionId: connectionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAllData() async {
        isLoading = true

        do {
            _ = try await serviceConnectionHandler.deleteData(connectionId: connectionId)
            dataRecords.removeAll()
            summary = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func exportAllData() async {
        isLoading = true

        do {
            let exportData = try await serviceConnectionHandler.exportData(connectionId: connectionId)

            // Write to temp file
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "vettid-export-\(Date().ISO8601Format()).json"
            let fileURL = tempDir.appendingPathComponent(fileName)

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let jsonData = try encoder.encode(exportData)
            try jsonData.write(to: fileURL)

            exportURL = fileURL
            showingExportSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func clearError() {
        errorMessage = nil
    }
}

#if DEBUG
struct ServiceDataTransparencyView_Previews: PreviewProvider {
    static var previews: some View {
        Text("ServiceDataTransparencyView Preview")
    }
}
#endif
