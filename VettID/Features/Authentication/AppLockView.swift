import SwiftUI
import LocalAuthentication

struct AppLockView: View {
    @ObservedObject var lockService: AppLockService
    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isShaking = false
    @State private var showBiometricPrompt = false

    var body: some View {
        ZStack {
            // Background
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 16) {
                    Image("VettIDLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Text("VettID")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Enter your PIN to unlock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Lockout message
                if lockService.isLockedOut, let timeRemaining = lockService.formattedLockoutTime {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.title)
                            .foregroundStyle(.red)

                        Text("Too many failed attempts")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Try again in \(timeRemaining)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(12)
                } else {
                    // PIN dots
                    HStack(spacing: 16) {
                        ForEach(0..<6) { index in
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

                    // Failed attempts indicator
                    if lockService.failedAttempts > 0 {
                        Text("\(lockService.failedAttempts) failed attempt\(lockService.failedAttempts > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                // Keypad
                if !lockService.isLockedOut {
                    PINKeypadView(pin: $pin, onComplete: attemptUnlock)
                }

                // Biometric button
                if lockService.shouldUseBiometrics && !lockService.isLockedOut {
                    Button(action: attemptBiometricUnlock) {
                        HStack {
                            Image(systemName: biometricIcon)
                                .font(.title2)

                            Text("Use \(biometricName)")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.blue)
                    }
                    .padding(.bottom, 20)
                }
            }
            .padding()
        }
        .onAppear {
            // Automatically prompt for biometrics if available
            if lockService.shouldUseBiometrics && !lockService.shouldUsePIN {
                attemptBiometricUnlock()
            }
        }
    }

    // MARK: - Helpers

    private func dotFill(for index: Int) -> Color {
        if index < pin.count {
            return .blue
        }
        return Color(.systemGray5)
    }

    private var biometricIcon: String {
        lockService.biometricType == .faceID ? "faceid" : "touchid"
    }

    private var biometricName: String {
        lockService.biometricType == .faceID ? "Face ID" : "Touch ID"
    }

    private func attemptUnlock() {
        guard pin.count >= 4 else { return }

        if lockService.unlockWithPIN(pin) {
            // Success - view will dismiss
            pin = ""
            errorMessage = nil
        } else {
            // Failure
            errorMessage = "Incorrect PIN"
            withAnimation(.default) {
                isShaking = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isShaking = false
                pin = ""
            }
        }
    }

    private func attemptBiometricUnlock() {
        Task {
            let success = await lockService.unlockWithBiometrics()
            if !success {
                errorMessage = "Biometric authentication failed"
            }
        }
    }
}

// MARK: - PIN Keypad View

struct PINKeypadView: View {
    @Binding var pin: String
    let onComplete: () -> Void

    private let keys = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "delete"]
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        keyButton(for: key)
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func keyButton(for key: String) -> some View {
        if key.isEmpty {
            Color.clear
                .frame(width: 70, height: 70)
        } else if key == "delete" {
            Button {
                if !pin.isEmpty {
                    pin.removeLast()
                }
            } label: {
                Image(systemName: "delete.left")
                    .font(.title2)
                    .frame(width: 70, height: 70)
                    .foregroundStyle(.primary)
            }
        } else {
            Button {
                if pin.count < 6 {
                    pin += key
                    if pin.count >= 4 {
                        // Small delay for visual feedback
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            onComplete()
                        }
                    }
                }
            } label: {
                Text(key)
                    .font(.title)
                    .fontWeight(.medium)
                    .frame(width: 70, height: 70)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 10
    var shakes: Int

    var animatableData: CGFloat {
        get { CGFloat(shakes) }
        set { shakes = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX:
            amount * sin(CGFloat(shakes) * .pi * 2),
            y: 0))
    }
}

// MARK: - Preview

#Preview("Locked") {
    AppLockView(lockService: {
        let service = AppLockService.shared
        service.isLocked = true
        return service
    }())
}
