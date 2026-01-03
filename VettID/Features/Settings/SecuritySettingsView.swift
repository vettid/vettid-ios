import SwiftUI
import LocalAuthentication

struct SecuritySettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var lockService = AppLockService.shared
    @State private var showPINSetup = false
    @State private var showChangePIN = false
    @State private var showPatternSetup = false
    @State private var showChangePattern = false
    @State private var showChangePassword = false
    @State private var biometricsAvailable = false
    @State private var biometricType: LABiometryType = .none

    var body: some View {
        List {
            // App Lock Section
            Section {
                Toggle("Enable App Lock", isOn: Binding(
                    get: { appState.appLock.isEnabled },
                    set: { newValue in
                        if newValue {
                            // If enabling, show appropriate setup based on method
                            if appState.appLock.method.requiresPIN {
                                showPINSetup = true
                            } else if appState.appLock.method.requiresPattern {
                                showPatternSetup = true
                            } else {
                                var settings = appState.appLock
                                settings.isEnabled = true
                                appState.appLock = settings
                            }
                        } else {
                            lockService.clearPIN()
                            lockService.clearPattern()
                        }
                    }
                ))
            } header: {
                Text("App Lock")
            } footer: {
                Text("Require authentication when opening the app after it's been in the background.")
            }

            // Lock Method Section
            if appState.appLock.isEnabled {
                Section("Lock Method") {
                    ForEach(availableLockMethods, id: \.rawValue) { method in
                        LockMethodRow(
                            method: method,
                            biometricType: biometricType,
                            isSelected: appState.appLock.method == method
                        ) {
                            selectLockMethod(method)
                        }
                    }
                }

                // Auto-Lock Timeout Section
                Section {
                    Picker("Auto-Lock", selection: Binding(
                        get: { appState.appLock.autoLockTimeout },
                        set: { newValue in
                            var settings = appState.appLock
                            settings.autoLockTimeout = newValue
                            appState.appLock = settings
                        }
                    )) {
                        ForEach(AutoLockTimeout.allCases, id: \.rawValue) { timeout in
                            Text(timeout.displayName).tag(timeout)
                        }
                    }
                } header: {
                    Text("Auto-Lock Timeout")
                } footer: {
                    Text("How long the app can be in the background before requiring authentication.")
                }

                // PIN Management
                if appState.appLock.method.requiresPIN {
                    Section {
                        Button("Change PIN") {
                            showChangePIN = true
                        }
                    }
                }

                // Pattern Management
                if appState.appLock.method.requiresPattern {
                    Section {
                        Button("Change Pattern") {
                            showChangePattern = true
                        }
                    }
                }
            }

            // Password Section
            Section {
                Button("Change Password") {
                    showChangePassword = true
                }
            } header: {
                Text("Vault Services Password")
            } footer: {
                Text("This is the password you use to authenticate with Vault Services.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkBiometrics()
        }
        .sheet(isPresented: $showPINSetup) {
            PINSetupView { pin in
                _ = lockService.setPIN(pin)
                // Refresh app state to pick up the new settings
                appState.preferences = UserPreferences.load()
            }
        }
        .sheet(isPresented: $showChangePIN) {
            PINSetupView(isChange: true) { pin in
                _ = lockService.setPIN(pin)
                appState.preferences = UserPreferences.load()
            }
        }
        .sheet(isPresented: $showPatternSetup) {
            PatternSetupView { pattern in
                _ = lockService.setPattern(pattern)
                appState.preferences = UserPreferences.load()
            }
        }
        .sheet(isPresented: $showChangePattern) {
            PatternSetupView(isChange: true) { pattern in
                _ = lockService.setPattern(pattern)
                appState.preferences = UserPreferences.load()
            }
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
        }
    }

    private var availableLockMethods: [AppLockMethod] {
        if biometricsAvailable {
            return AppLockMethod.allCases
        } else {
            return [.pin]
        }
    }

    private func checkBiometrics() {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometricsAvailable = true
            biometricType = context.biometryType
        } else {
            biometricsAvailable = false
            biometricType = .none
        }
    }

    private func selectLockMethod(_ method: AppLockMethod) {
        // Show setup for PIN methods if no PIN set
        if method.requiresPIN && appState.appLock.pinHash == nil {
            showPINSetup = true
        }
        // Show setup for pattern methods if no pattern set
        if method.requiresPattern && appState.appLock.patternHash == nil {
            showPatternSetup = true
        }
        var settings = appState.appLock
        settings.method = method
        appState.appLock = settings
    }
}

// MARK: - Lock Method Row

struct LockMethodRow: View {
    let method: AppLockMethod
    let biometricType: LABiometryType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch method {
        case .pin:
            return "lock.fill"
        case .pattern:
            return "square.grid.3x3.fill"
        case .biometrics:
            return biometricType == .faceID ? "faceid" : "touchid"
        case .both:
            return "lock.shield.fill"
        case .patternBiometrics:
            return "square.grid.3x3.topleft.filled"
        }
    }

    private var displayName: String {
        let bioName = biometricType == .faceID ? "Face ID" : "Touch ID"
        switch method {
        case .pin:
            return "PIN"
        case .pattern:
            return "Pattern"
        case .biometrics:
            return bioName
        case .both:
            return "PIN & \(bioName)"
        case .patternBiometrics:
            return "Pattern & \(bioName)"
        }
    }

    private var description: String {
        let bioName = biometricType == .faceID ? "Face ID" : "Touch ID"
        switch method {
        case .pin:
            return "Use a 4-6 digit PIN"
        case .pattern:
            return "Draw a pattern to unlock"
        case .biometrics:
            return "Use \(bioName) to unlock"
        case .both:
            return "Use both for maximum security"
        case .patternBiometrics:
            return "Pattern with \(bioName) fallback"
        }
    }
}

// MARK: - PIN Setup View

struct PINSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var isChange: Bool = false
    let onComplete: (String) -> Void

    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step: PINSetupStep = .enter
    @State private var errorMessage: String?

    enum PINSetupStep {
        case enter
        case confirm
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()

                // Icon
                Image(systemName: "lock.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                // Title
                Text(stepTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(stepSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // PIN dots
                HStack(spacing: 16) {
                    ForEach(0..<6) { index in
                        Circle()
                            .fill(dotFill(for: index))
                            .frame(width: 16, height: 16)
                    }
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                // Keypad
                PINKeypad(pin: step == .enter ? $pin : $confirmPin) {
                    handleInput()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .enter:
            return isChange ? "Enter New PIN" : "Create PIN"
        case .confirm:
            return "Confirm PIN"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .enter:
            return "Enter a 4-6 digit PIN"
        case .confirm:
            return "Enter your PIN again to confirm"
        }
    }

    private var currentPin: String {
        step == .enter ? pin : confirmPin
    }

    private func dotFill(for index: Int) -> Color {
        if index < currentPin.count {
            return .blue
        }
        return Color(.systemGray4)
    }

    private func handleInput() {
        errorMessage = nil

        if step == .enter && pin.count >= 4 {
            step = .confirm
        } else if step == .confirm && confirmPin.count >= pin.count {
            if confirmPin == pin {
                onComplete(pin)
                dismiss()
            } else {
                errorMessage = "PINs don't match. Try again."
                confirmPin = ""
                step = .enter
                pin = ""
            }
        }
    }
}

// MARK: - PIN Keypad

struct PINKeypad: View {
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
                                        onComplete()
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
            }
        }
        .padding(.bottom, 32)
    }
}

// MARK: - Change Password Sheet

struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var passwordChanged = false

    private let apiClient = APIClient()
    private let authTokenProvider: () -> String?

    init(authTokenProvider: @escaping () -> String? = { nil }) {
        self.authTokenProvider = authTokenProvider
    }

    var body: some View {
        NavigationView {
            Group {
                if passwordChanged {
                    successView
                } else {
                    formView
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var formView: some View {
        Form {
            Section {
                SecureField("Current Password", text: $currentPassword)
            } header: {
                Text("Current Password")
            }

            Section {
                SecureField("New Password", text: $newPassword)
                SecureField("Confirm New Password", text: $confirmPassword)
            } header: {
                Text("New Password")
            } footer: {
                Text("Password must be at least 8 characters.")
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: changePassword) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Change Password")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!isValid || isLoading)
            }
        }
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Password Changed")
                .font(.title2)
                .fontWeight(.bold)

            Text("Your password has been updated successfully.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private var isValid: Bool {
        !currentPassword.isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmPassword
    }

    private func changePassword() {
        guard isValid else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Hash the new password using PasswordHasher
                let result = try PasswordHasher.hash(password: newPassword)

                // In a full implementation, this would:
                // 1. Verify current password with the server
                // 2. Re-encrypt vault keys with new password
                // 3. Update password hash on server

                // For now, update local secrets store password hash
                let secretsStore = SecretsStore()
                try secretsStore.storePasswordHash(result.hash, salt: result.salt)

                await MainActor.run {
                    isLoading = false
                    passwordChanged = true
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Failed to change password: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Pattern Setup View

struct PatternSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var isChange: Bool = false
    let onComplete: ([Int]) -> Void

    @State private var pattern: [Int] = []
    @State private var confirmPattern: [Int] = []
    @State private var patternError = false
    @State private var step: PatternSetupStep = .enter
    @State private var errorMessage: String?

    enum PatternSetupStep {
        case enter
        case confirm
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()

                // Icon
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                // Title
                Text(stepTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(stepSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Pattern grid
                PatternGridView(
                    pattern: step == .enter ? $pattern : $confirmPattern,
                    isError: $patternError
                ) { completedPattern in
                    handlePatternComplete(completedPattern)
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                // Instructions
                Text("Connect at least 4 dots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .enter:
            return isChange ? "Draw New Pattern" : "Create Pattern"
        case .confirm:
            return "Confirm Pattern"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .enter:
            return "Draw a pattern to use for unlocking"
        case .confirm:
            return "Draw your pattern again to confirm"
        }
    }

    private func handlePatternComplete(_ completedPattern: [Int]) {
        errorMessage = nil

        if step == .enter {
            // Validate pattern length
            let validation = PatternAuthenticator.validate(completedPattern)
            if validation.isValid {
                pattern = completedPattern
                step = .confirm
                // Clear for confirm step
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Pattern will be cleared by the grid view automatically
                }
            } else {
                errorMessage = validation.errorMessage
                patternError = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pattern = []
                    patternError = false
                }
            }
        } else {
            // Confirm step - check if patterns match
            if completedPattern == pattern {
                onComplete(pattern)
                dismiss()
            } else {
                errorMessage = "Patterns don't match. Try again."
                patternError = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    confirmPattern = []
                    patternError = false
                    step = .enter
                    pattern = []
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SecuritySettingsView()
    }
    .environmentObject(AppState())
}
