import SwiftUI
import UIKit

// MARK: - Connection Error Types

/// Typed errors for connections with recovery suggestions
enum ConnectionError: Error, Equatable {
    case networkUnavailable
    case invitationExpired
    case invitationAlreadyUsed
    case connectionRejected
    case vaultUnavailable
    case cryptoFailure
    case peerUnreachable
    case rateLimited
    case unknown(String)

    var title: String {
        switch self {
        case .networkUnavailable: return "No Internet Connection"
        case .invitationExpired: return "Invitation Expired"
        case .invitationAlreadyUsed: return "Invitation Already Used"
        case .connectionRejected: return "Connection Rejected"
        case .vaultUnavailable: return "Vault Unavailable"
        case .cryptoFailure: return "Security Error"
        case .peerUnreachable: return "Peer Unreachable"
        case .rateLimited: return "Too Many Requests"
        case .unknown: return "Something Went Wrong"
        }
    }

    var description: String {
        switch self {
        case .networkUnavailable:
            return "Check your internet connection and try again."
        case .invitationExpired:
            return "This invitation has expired. Ask the sender to create a new one."
        case .invitationAlreadyUsed:
            return "This invitation has already been used by someone else."
        case .connectionRejected:
            return "The connection request was declined."
        case .vaultUnavailable:
            return "Your vault is currently unavailable. Try again later."
        case .cryptoFailure:
            return "A security error occurred. Please try again."
        case .peerUnreachable:
            return "Could not reach the other person. They may be offline."
        case .rateLimited:
            return "Too many attempts. Please wait a moment and try again."
        case .unknown(let message):
            return message
        }
    }

    var icon: String {
        switch self {
        case .networkUnavailable: return "wifi.slash"
        case .invitationExpired: return "clock.badge.xmark"
        case .invitationAlreadyUsed: return "person.fill.xmark"
        case .connectionRejected: return "hand.raised.slash"
        case .vaultUnavailable: return "lock.shield"
        case .cryptoFailure: return "exclamationmark.shield"
        case .peerUnreachable: return "person.crop.circle.badge.questionmark"
        case .rateLimited: return "hourglass"
        case .unknown: return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .networkUnavailable, .vaultUnavailable, .peerUnreachable:
            return Color(hex: "#FF9800")  // Orange - temporary issues
        case .invitationExpired, .invitationAlreadyUsed, .connectionRejected:
            return Color(hex: "#F44336")  // Red - permanent issues
        case .cryptoFailure:
            return Color(hex: "#9C27B0")  // Purple - security issues
        case .rateLimited:
            return Color(hex: "#2196F3")  // Blue - wait issues
        case .unknown:
            return Color(hex: "#9E9E9E")  // Gray - unknown
        }
    }

    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .vaultUnavailable, .peerUnreachable, .rateLimited, .cryptoFailure:
            return true
        case .invitationExpired, .invitationAlreadyUsed, .connectionRejected, .unknown:
            return false
        }
    }
}

/// Recovery action for an error
struct RecoveryAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let isPrimary: Bool
    let action: () -> Void
}

// MARK: - Color Extension (Hex Support)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Connection Error Card

/// Error card with recovery options
struct ConnectionErrorCard: View {
    let error: ConnectionError
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void
    let recoveryActions: [RecoveryAction]

    init(
        error: ConnectionError,
        onRetry: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        recoveryActions: [RecoveryAction] = []
    ) {
        self.error = error
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        self.recoveryActions = recoveryActions
    }

    var body: some View {
        VStack(spacing: 16) {
            // Error icon
            Circle()
                .fill(error.color.opacity(0.1))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: error.icon)
                        .font(.title)
                        .foregroundStyle(error.color)
                }

            // Error info
            VStack(spacing: 8) {
                Text(error.title)
                    .font(.headline)

                Text(error.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Recovery actions
            VStack(spacing: 8) {
                // Default retry button
                if error.isRetryable, let onRetry = onRetry {
                    Button(action: onRetry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Custom recovery actions
                ForEach(recoveryActions) { action in
                    Button(action: action.action) {
                        Label(action.label, systemImage: action.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(action.isPrimary ? .borderedProminent : .bordered)
                }

                // Dismiss button
                Button("Dismiss", action: onDismiss)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Inline Error Banner

/// Inline error banner for lists
struct InlineErrorBanner: View {
    let error: ConnectionError
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: error.icon)
                .foregroundStyle(error.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(error.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if error.isRetryable, let onRetry = onRetry {
                Button("Retry", action: onRetry)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(error.color.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Retry State Wrapper

/// View modifier for handling retry state
struct RetryableView<Content: View, FailureContent: View>: View {
    let isLoading: Bool
    let error: ConnectionError?
    let onRetry: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let failureContent: () -> FailureContent

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = error {
            VStack {
                failureContent()

                ConnectionErrorCard(
                    error: error,
                    onRetry: onRetry,
                    onDismiss: {}
                )
            }
        } else {
            content()
        }
    }
}

// MARK: - Network Status Banner

/// Banner showing network status
struct NetworkStatusBanner: View {
    let isOffline: Bool
    let pendingOperations: Int

    var body: some View {
        if isOffline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.caption)

                Text("Offline")
                    .font(.caption)
                    .fontWeight(.medium)

                if pendingOperations > 0 {
                    Text("\u{2022} \(pendingOperations) pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.2))
            .foregroundStyle(.orange)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ErrorRecoveryComponents_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            ConnectionErrorCard(
                error: .networkUnavailable,
                onRetry: {},
                onDismiss: {}
            )

            InlineErrorBanner(
                error: .invitationExpired,
                onRetry: nil,
                onDismiss: {}
            )

            NetworkStatusBanner(
                isOffline: true,
                pendingOperations: 3
            )
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
    }
}
#endif
