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
    @State private var retryCount = 0
    @FocusState private var isPinFieldFocused: Bool

    // #56 — pre-PIN PCR0 trust check. When the current enclave PCR0 is
    // not in the user's trusted set, we hold the typed PIN and show
    // the enclave-update prompt. Approval rides as `migrate_consent=true`
    // on the resubmit; Not Now sets `skipPcr0Check` for this session.
    @State private var showEnclaveUpdate = false
    @State private var pendingUntrustedPcr0: String?
    @State private var skipPcr0Check: Bool = false
    @State private var migrateConsentPending: Bool = false

    /// Maximum number of automatic retries when vault is not ready
    private let maxAutoRetries = 3
    /// Delay between automatic retries in seconds
    private let retryDelay: UInt64 = 2_000_000_000

    // Android-parity PIN bounds (4–8 digits, matching enrollment).
    private let minPinLength = 4
    private let maxPinLength = 8

    @State private var showStartOverConfirm = false

    let onSuccess: () -> Void

    /// Welcome message using the user's first name if available
    private var welcomeMessage: String {
        if let profile = appState.currentProfile {
            let firstName = profile.displayName.split(separator: " ").first.map(String.init) ?? profile.displayName
            return "Welcome back, \(firstName)"
        }
        return "Unlock Vault"
    }

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

                Text(welcomeMessage)
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
                    // PIN dots — show one dot per typed digit, up to
                    // the 8-digit cap that matches the Android-parity
                    // enrollment range. The dots grow with the PIN
                    // rather than always reserving 6 slots.
                    HStack(spacing: 12) {
                        ForEach(0..<maxPinLength, id: \.self) { index in
                            Circle()
                                .fill(dotFill(for: index))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Circle()
                                        .stroke(Color(.systemGray3), lineWidth: 1)
                                )
                                .opacity(index < pin.count || index < minPinLength ? 1 : 0.35)
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

                    // Hidden text field for keyboard input (4–8 digit
                    // PINs, manual submit). Auto-submit removed — the
                    // Android-parity enrollment now lets users pick
                    // any length in [4,8], so we don't know when to
                    // stop without an explicit confirm.
                    TextField("", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($isPinFieldFocused)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .onChange(of: pin) { newValue in
                            var cleaned = newValue.filter { $0.isNumber }
                            if cleaned.count > maxPinLength {
                                cleaned = String(cleaned.prefix(maxPinLength))
                            }
                            if cleaned != newValue { pin = cleaned }
                        }
                }

                Spacer()

                // Keypad + explicit Unlock submit. Matches Android's
                // `PinEntryContent` — keypad accumulates digits, the
                // Unlock button fades in once >= MIN_PIN_LENGTH.
                if !isWarming {
                    PINKeypadView(
                        pin: $pin,
                        onComplete: {},
                        maxLength: maxPinLength,
                        autoSubmit: false
                    )

                    Button {
                        attemptWarmVault()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open.fill")
                            Text("Unlock")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 48)
                    .opacity(pin.count >= minPinLength ? 1 : 0)
                    .disabled(pin.count < minPinLength)
                    .animation(.easeInOut(duration: 0.15), value: pin.count >= minPinLength)
                } else {
                    ProgressView("Unlocking vault...")
                        .padding()
                }
            }

            Spacer()

            // Subtle "Start over" — Android doesn't surface this, but
            // we keep it for the case where the user is testing with a
            // stale credential. Tiny text link, not a button, so it's
            // not a confusing primary action.
            Button {
                showStartOverConfirm = true
            } label: {
                Text("Start over")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
            .accessibilityIdentifier("vaultWarming.startOver")
        }
        .padding()
        .onAppear {
            isPinFieldFocused = true
        }
        .alert("Start over with a new enrollment?", isPresented: $showStartOverConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Start Over", role: .destructive) {
                appState.fullSignOut()
            }
        } message: {
            Text("This clears the credential stored on this device. You'll go back to the welcome screen and can enroll a new identity. The vault on the server is not affected.")
        }
        // #56 — Enclave Update Required sheet. Fires when the running
        // PCR0 isn't in the user's trusted set; Approve adds it and
        // resubmits with migrate_consent=true, Not Now skips PCR0 check
        // for this session and resubmits against the current enclave.
        .sheet(isPresented: $showEnclaveUpdate) {
            EnclaveUpdatePromptView(
                pcr0: pendingUntrustedPcr0 ?? "",
                onApprove: {
                    if let guid = appState.currentUserGuid,
                       let pcr0 = pendingUntrustedPcr0 {
                        TrustedPCRStore.shared.add(pcr0: pcr0, for: guid)
                    }
                    migrateConsentPending = true
                    pendingUntrustedPcr0 = nil
                    showEnclaveUpdate = false
                    attemptWarmVault()
                },
                onSkip: {
                    skipPcr0Check = true
                    pendingUntrustedPcr0 = nil
                    showEnclaveUpdate = false
                    attemptWarmVault()
                }
            )
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
        guard (minPinLength...maxPinLength).contains(pin.count) else { return }
        guard !isWarming else { return }

        // SECURITY (Area E #97): durable rate-limit. Survives process
        // restart, so a stolen device can't be brute-forced by
        // kill/relaunch loops. UnlockRateLimiter handles per-session
        // exponential backoff; PinAttemptTracker enforces the
        // wall-clock lockout that crosses launches.
        let tracker = PinAttemptTracker.shared
        if tracker.isLockedOut() {
            errorMessage = "Too many attempts. Try again in \(tracker.lockoutLabel())."
            shakeAndClearPIN()
            return
        }

        // #56 — pre-PIN PCR0 trust check. Skip when the user already
        // tapped "Not Now" this session, or when there's no user GUID
        // yet (pre-warm state). On bootstrap (no recorded trusted set)
        // we silently add the current PCR0 — the user enrolled before
        // this surface existed and we'd otherwise gate them forever.
        if !skipPcr0Check, let guid = appState.currentUserGuid,
           let currentPcr0 = ExpectedPCRStore.shared.getCurrentPCRSet()?.pcr0,
           !currentPcr0.isEmpty {
            let store = TrustedPCRStore.shared
            if store.isBootstrap(for: guid) {
                store.add(pcr0: currentPcr0, for: guid)
            } else if !store.isTrusted(pcr0: currentPcr0, for: guid) {
                pendingUntrustedPcr0 = currentPcr0
                showEnclaveUpdate = true
                return
            }
        }

        isWarming = true
        errorMessage = nil
        retryCount = 0

        Task {
            await warmVaultWithRetry(migrateConsent: migrateConsentPending)
        }
    }

    /// Attempt to warm vault with automatic retry for vault-not-ready scenarios.
    /// Phase 5.7 — also retries the `pending_new_enclave` migration race
    /// reported by the vault when Phase 4.6 routing reclaim hasn't
    /// settled yet, with the same calm "Updating vault…" UX as Android.
    private func warmVaultWithRetry(migrateConsent: Bool = false) async {
        do {
            try await appState.warmVault(pin: pin, migrateConsent: migrateConsent)

            // Phase 5.7 — react to the M1 migration verdict.
            switch appState.lastMigrationStatus {
            case "pending_new_enclave":
                // Routing race — the vault answered against OLD even
                // though Phase 4.6 reclaim should have brought NEW up.
                // Retry with the same migrateConsent flag a bounded
                // number of times. UX stays calm — no red error.
                if retryCount < maxAutoRetries {
                    retryCount += 1
                    await MainActor.run {
                        errorMessage = "Finishing vault update… (attempt \(retryCount)/\(maxAutoRetries))"
                    }
                    try? await Task.sleep(nanoseconds: retryDelay)
                    await warmVaultWithRetry(migrateConsent: migrateConsent)
                } else {
                    await MainActor.run {
                        errorMessage = "Vault update is taking longer than usual. Please try unlocking again in a minute."
                        isWarming = false
                    }
                }
                return
            case "failed":
                await MainActor.run {
                    errorMessage = "Vault update failed. Please try again or contact support."
                    isWarming = false
                }
                return
            default:
                break // "completed", "not_requested", "" / nil — all proceed.
            }

            appState.loadProfile()
            // SECURITY (Area E #97): a real unlock zeroes the durable
            // failure counter. Vault-not-ready / migration-race
            // failures DON'T count against the user — they're not PIN
            // errors. recordFailure is gated to the catch branches
            // that look like wrong-PIN responses.
            PinAttemptTracker.shared.reset()
            await MainActor.run {
                isWarming = false
                onSuccess()
            }
        } catch let error as VaultWarmingError {
            await MainActor.run {
                // Wrong-PIN cases (invalidPIN, warmingFailed with auth
                // error) count against the durable tracker; transport
                // failures don't.
                if case .invalidPIN = error {
                    let lockoutSeconds = PinAttemptTracker.shared.recordFailure()
                    if lockoutSeconds > 0 {
                        errorMessage = "Too many attempts. Try again in \(PinAttemptTracker.shared.lockoutLabel())."
                        shakeAndClearPIN()
                        isWarming = false
                        return
                    }
                }
                handleWarmingError(error)
            }
        } catch {
            // Check if this is a vault-not-ready situation (retry automatically)
            if retryCount < maxAutoRetries && isVaultNotReady(error) {
                retryCount += 1
                #if DEBUG
                print("[VaultWarming] Vault not ready, retry \(retryCount)/\(maxAutoRetries) in 2s...")
                #endif
                errorMessage = "Vault initializing... (attempt \(retryCount)/\(maxAutoRetries))"
                try? await Task.sleep(nanoseconds: retryDelay)
                await warmVaultWithRetry(migrateConsent: migrateConsent)
            } else {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isWarming = false
                    shakeAndClearPIN()
                }
            }
        }
    }

    /// Detect if an error indicates the vault is not ready yet
    private func isVaultNotReady(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("not ready") ||
               message.contains("initializing") ||
               message.contains("starting") ||
               message.contains("unavailable")
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
