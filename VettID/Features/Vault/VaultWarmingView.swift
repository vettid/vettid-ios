import SwiftUI

/// View for entering PIN to warm the vault (Architecture v2.0 Section 5.8)
///
/// This view is shown after authentication when the vault is cold.
/// The user enters their PIN, which is sent to the supervisor via NATS
/// to derive the DEK and load it into memory.
struct VaultWarmingView: View {
    @EnvironmentObject var appState: AppState
    @State private var pin = ""
    @State private var isWarming = false
    @State private var errorMessage: String?
    @State private var remainingAttempts: Int?
    @State private var isShaking = false
    @FocusState private var isPinFieldFocused: Bool

    let onSuccess: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo and title
            VStack(spacing: 16) {
                Image("VettIDLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Text("Unlock Vault")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Enter your PIN to unlock your vault")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Lockout message
            if case .lockedOut(let retryAfter) = appState.vaultTemperature {
                lockoutView(retryAfter: retryAfter)
            } else {
                // PIN entry
                VStack(spacing: 20) {
                    // PIN dots
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { index in
                            Circle()
                                .fill(dotFill(for: index))
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle()
                                        .stroke(Color(.systemGray3), lineWidth: 1)
                                )
                        }
                    }
                    .modifier(ShakeEffect(shakes: isShaking ? 2 : 0))

                    // Error message
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Remaining attempts indicator
                    if let attempts = remainingAttempts, attempts < 3 {
                        Text("\(attempts) attempt\(attempts == 1 ? "" : "s") remaining")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    // Hidden text field for keyboard input
                    TextField("", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($isPinFieldFocused)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .onChange(of: pin) { newValue in
                            // Limit to 6 digits
                            if newValue.count > 6 {
                                pin = String(newValue.prefix(6))
                            }
                            // Only allow numbers
                            pin = newValue.filter { $0.isNumber }

                            // Auto-submit when 6 digits entered
                            if pin.count == 6 {
                                attemptWarmVault()
                            }
                        }
                }

                Spacer()

                // Keypad
                if !isWarming {
                    PINKeypadView(pin: $pin) {
                        if pin.count == 6 {
                            attemptWarmVault()
                        }
                    }
                } else {
                    ProgressView("Unlocking vault...")
                        .padding()
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            isPinFieldFocused = true
        }
    }

    // MARK: - Lockout View

    private func lockoutView(retryAfter: Date?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Too Many Failed Attempts")
                .font(.headline)

            if let retryDate = retryAfter {
                Text("Try again \(retryDate, style: .relative)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Please try again later")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(16)
    }

    // MARK: - Helpers

    private func dotFill(for index: Int) -> Color {
        if index < pin.count {
            return .blue
        }
        return Color(.systemGray5)
    }

    private func attemptWarmVault() {
        guard pin.count == 6 else { return }
        guard !isWarming else { return }

        isWarming = true
        errorMessage = nil

        Task {
            do {
                try await appState.warmVault(pin: pin)
                // Success - call completion handler
                await MainActor.run {
                    isWarming = false
                    onSuccess()
                }
            } catch let error as VaultWarmingError {
                await MainActor.run {
                    handleWarmingError(error)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isWarming = false
                    shakeAndClearPIN()
                }
            }
        }
    }

    private func handleWarmingError(_ error: VaultWarmingError) {
        isWarming = false

        switch error {
        case .lockedOut:
            // Lockout state is handled by the view automatically via appState
            errorMessage = nil
        case .warmingFailed(let message):
            errorMessage = message
            shakeAndClearPIN()
        case .notConnected:
            errorMessage = "Not connected to vault"
            shakeAndClearPIN()
        case .invalidPIN:
            errorMessage = "Invalid PIN"
            shakeAndClearPIN()
        }
    }

    private func shakeAndClearPIN() {
        withAnimation(.default) {
            isShaking = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isShaking = false
            pin = ""
        }
    }
}

// MARK: - Preview

#Preview {
    VaultWarmingView {
        print("Vault warmed!")
    }
    .environmentObject(AppState())
}
