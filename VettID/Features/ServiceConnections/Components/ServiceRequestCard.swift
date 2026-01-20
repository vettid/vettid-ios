import SwiftUI

/// Card displaying a service request in the unified feed
struct ServiceRequestCard: View {
    let request: ServiceRequest
    let serviceProfile: ServiceProfile
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onViewDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Service Header
            HStack {
                ServiceLogoView(url: serviceProfile.serviceLogoUrl, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(serviceProfile.serviceName)
                            .font(.headline)
                            .lineLimit(1)

                        if serviceProfile.organization.verified {
                            VerificationBadge(type: serviceProfile.organization.verificationType)
                        }
                    }

                    Text(request.type.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(request.requestedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Request Content
            VStack(alignment: .leading, spacing: 6) {
                if let purpose = request.purpose {
                    Text(purpose)
                        .font(.subheadline)
                }

                // Type-specific content
                switch request.type {
                case .data:
                    if let fields = request.requestedFields, !fields.isEmpty {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.blue)
                            Text("Requesting: \(fields.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                case .payment:
                    if let amount = request.amount {
                        HStack {
                            Image(systemName: "creditcard.fill")
                                .foregroundColor(.green)
                            Text(amount.formatted)
                                .font(.headline)
                        }
                    }

                case .auth:
                    HStack {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundColor(.orange)
                        Text("Identity verification requested")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                case .consent:
                    if let action = request.requestedAction {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.purple)
                            Text(action)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Expiration Warning
            if let expiresAt = Calendar.current.dateComponents([.hour], from: Date(), to: request.expiresAt).hour,
               expiresAt < 24 {
                HStack {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Expires in \(request.expiresAt, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Action Buttons
            HStack(spacing: 12) {
                Button(action: onDeny) {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onApprove) {
                    Text("Approve")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .onTapGesture {
            onViewDetails()
        }
    }
}

// MARK: - Compact Service Request Row

/// Compact version for list display
struct ServiceRequestRow: View {
    let request: ServiceRequest
    let serviceProfile: ServiceProfile

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: request.type.icon)
                .foregroundColor(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(serviceProfile.serviceName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(request.type.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                ServiceRequestStatusBadge(status: request.status)

                Text(request.requestedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var iconColor: Color {
        switch request.type {
        case .data: return .blue
        case .auth: return .orange
        case .consent: return .purple
        case .payment: return .green
        }
    }
}

// MARK: - Service Request Status Badge

struct ServiceRequestStatusBadge: View {
    let status: ServiceRequestStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .cornerRadius(4)
    }

    private var textColor: Color {
        switch status {
        case .pending: return .orange
        case .approved: return .green
        case .denied: return .red
        case .expired: return .gray
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending: return .orange.opacity(0.2)
        case .approved: return .green.opacity(0.2)
        case .denied: return .red.opacity(0.2)
        case .expired: return .gray.opacity(0.2)
        }
    }
}

// MARK: - Service Requests List View

/// View for listing all service requests
struct ServiceRequestsListView: View {
    let requests: [ServiceRequest]
    let serviceProfiles: [String: ServiceProfile]
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    @State private var filter: ServiceRequestStatus?

    var filteredRequests: [ServiceRequest] {
        guard let filter = filter else { return requests }
        return requests.filter { $0.status == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterPill(title: "All", isSelected: filter == nil) {
                        filter = nil
                    }

                    ForEach([ServiceRequestStatus.pending, .approved, .denied, .expired], id: \.self) { status in
                        FilterPill(title: status.displayName, isSelected: filter == status) {
                            filter = status
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            if filteredRequests.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)

                    Text("No requests")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredRequests) { request in
                    if let profile = serviceProfiles[request.connectionId] {
                        ServiceRequestRow(request: request, serviceProfile: profile)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Service Requests")
    }
}

struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
        }
    }
}

#if DEBUG
struct ServiceRequestCard_Previews: PreviewProvider {
    static var previews: some View {
        Text("ServiceRequestCard Preview")
    }
}
#endif
