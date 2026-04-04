import SwiftUI

/// Card shown post-vault-unlock when a migration update is available.
struct VaultUpdateCard: View {

    @ObservedObject var viewModel: VaultUpdateViewModel

    var body: some View {
        switch viewModel.state {
        case .checking:
            EmptyView()
        case .noUpdate:
            EmptyView()
        case .updateAvailable(let config, let isMandatory):
            updateAvailableCard(config: config, isMandatory: isMandatory)
        case .updating:
            updatingCard
        case .updated:
            successCard
        case .error(let message):
            errorCard(message)
        }
    }

    // MARK: - Update Available

    private func updateAvailableCard(config: MigrationConfig, isMandatory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.rotation")
                    .font(.title3)
                    .foregroundColor(.blue)
                Text("Vault Update Available")
                    .font(.headline)
            }

            Text(config.summary)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let url = config.detailsUrl, let link = URL(string: url) {
                Link("Review Details", destination: link)
                    .font(.caption)
            }

            HStack(spacing: 12) {
                Button("Update Now") {
                    Task { await viewModel.startUpdate() }
                }
                .buttonStyle(.borderedProminent)

                if !isMandatory {
                    Button("Remind Me Later") {
                        viewModel.remindLater()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    // MARK: - Updating

    private var updatingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Updating vault security...")
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    // MARK: - Success

    private var successCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Vault updated successfully")
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.1))
        )
        .padding(.horizontal)
    }

    // MARK: - Error

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.startUpdate() }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.05))
        )
        .padding(.horizontal)
    }
}
