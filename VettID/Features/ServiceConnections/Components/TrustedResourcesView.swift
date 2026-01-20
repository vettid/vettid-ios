import SwiftUI
import UIKit

/// Full view for displaying trusted resources from a service
struct TrustedResourcesView: View {
    let resources: [TrustedResource]
    @Environment(\.dismiss) private var dismiss

    var groupedResources: [TrustedResourceType: [TrustedResource]] {
        Dictionary(grouping: resources) { $0.type }
    }

    var body: some View {
        NavigationView {
            List {
                // Info Banner
                Section {
                    TrustedResourcesInfoBanner()
                }

                // Grouped by type
                ForEach(TrustedResourceType.allCases, id: \.self) { type in
                    if let typeResources = groupedResources[type], !typeResources.isEmpty {
                        Section(header: Text(type.sectionTitle)) {
                            ForEach(typeResources) { resource in
                                TrustedResourceDetailRow(resource: resource)
                            }
                        }
                    }
                }

                // Empty state
                if resources.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)

                            Text("No Trusted Resources")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Text("This service hasn't published any verified resources")
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
            .navigationTitle("Trusted Resources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Info Banner

struct TrustedResourcesInfoBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text("Verified Resources")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("These resources have been verified as belonging to this organization. Always use these official links to avoid phishing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Trusted Resource Detail Row

struct TrustedResourceDetailRow: View {
    let resource: TrustedResource

    @State private var showingCopiedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: resource.type.icon)
                    .foregroundColor(resource.type.color)
                    .frame(width: 24)

                Text(resource.label)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // All trusted resources are verified by definition
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }

            // URL or value
            Text(resource.url)
                .font(.caption)
                .foregroundColor(.blue)
                .lineLimit(2)

            // Description if available
            if let description = resource.description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Download info if available
            if let download = resource.download {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text("\(download.platform) • \(download.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Action buttons
            HStack(spacing: 16) {
                if let url = URL(string: resource.url) {
                    Link(destination: url) {
                        Label("Open", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }

                Button {
                    UIPasteboard.general.string = resource.url
                    showingCopiedConfirmation = true
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .overlay {
            if showingCopiedConfirmation {
                CopiedConfirmationOverlay()
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showingCopiedConfirmation = false
                        }
                    }
            }
        }
    }
}

// MARK: - Copied Confirmation Overlay

struct CopiedConfirmationOverlay: View {
    var body: some View {
        HStack {
            Image(systemName: "checkmark")
            Text("Copied")
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.8))
        .cornerRadius(8)
    }
}

// MARK: - Trusted Resource Type Extension

extension TrustedResourceType: CaseIterable {
    static var allCases: [TrustedResourceType] {
        [.website, .appDownload, .document, .api]
    }

    var sectionTitle: String {
        switch self {
        case .website: return "Websites"
        case .appDownload: return "App Downloads"
        case .document: return "Documents"
        case .api: return "API Endpoints"
        }
    }

    var color: Color {
        switch self {
        case .website: return .blue
        case .appDownload: return .green
        case .document: return .orange
        case .api: return .purple
        }
    }
}

// MARK: - Compact Trusted Resources Section

/// Compact section for trusted resources in detail view
struct TrustedResourcesCompactSection: View {
    let resources: [TrustedResource]
    let onViewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trusted Resources")
                    .font(.headline)
                Spacer()
                Button("View All", action: onViewAll)
                    .font(.caption)
            }

            // Show first few resources
            ForEach(resources.prefix(3)) { resource in
                TrustedResourceCompactRow(resource: resource)
            }

            if resources.count > 3 {
                HStack {
                    Spacer()
                    Text("+\(resources.count - 3) more")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct TrustedResourceCompactRow: View {
    let resource: TrustedResource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: resource.type.icon)
                .foregroundColor(resource.type.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(resource.label)
                    .font(.subheadline)
                Text(resource.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let url = URL(string: resource.url) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

// MARK: - Trusted Resource Verification Badge

struct TrustedResourceBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
            Text("Verified")
                .foregroundColor(.green)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
    }
}

#if DEBUG
struct TrustedResourcesView_Previews: PreviewProvider {
    static var previews: some View {
        Text("TrustedResourcesView Preview")
    }
}
#endif
