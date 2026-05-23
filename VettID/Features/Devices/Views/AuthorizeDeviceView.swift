import SwiftUI

/// Stage-2 desktop authorization. The user scans the QR shown on the
/// desktop, picks a session duration + device name, and approves —
/// which submits `device.authorize-session` to the vault. Mirrors
/// Android `AuthorizeDeviceScreen`.
struct AuthorizeDeviceView: View {
    let connectionId: String

    @StateObject private var viewModel: AuthorizeDeviceViewModel
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.connectionId = connectionId
        self._viewModel = StateObject(wrappedValue: AuthorizeDeviceViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .scanning:
                scanningView
            case .ready(_, let info, let deviceName, let durationSeconds):
                authorizeForm(info: info, deviceName: deviceName, durationSeconds: durationSeconds)
            case .submitting:
                progressView("Authorizing…")
            case .confirmReplace(_, _, _, _, let existing):
                confirmReplaceView(existing: existing)
            case .done:
                doneView
            case .error(let message):
                errorView(message: message)
            }
        }
        .navigationTitle("Authorize Desktop")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setPendingFromNotification(connectionId: connectionId)
        }
        .onChange(of: viewModelStateDescription) { _ in
            // Auto-dismiss on Done after the user sees the success
            // checkmark briefly. Matches Android's onNavigateBack
            // wiring from the LaunchedEffect(state) → DONE branch.
            if case .done = viewModel.state {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    dismiss()
                }
            }
        }
    }

    // Surface a stable Equatable key so onChange fires on transitions.
    private var viewModelStateDescription: String {
        switch viewModel.state {
        case .scanning: return "scanning"
        case .ready: return "ready"
        case .submitting: return "submitting"
        case .confirmReplace: return "confirmReplace"
        case .done: return "done"
        case .error(let m): return "error:\(m)"
        }
    }

    // MARK: - Sub-views

    private var scanningView: some View {
        VStack(spacing: 16) {
            Text("Scan the QR shown on your desktop")
                .font(.headline)
                .padding(.top, 16)
                .padding(.horizontal)
                .multilineTextAlignment(.center)

            ZStack {
                QRCodeScannerView(onScan: { code in
                    viewModel.onQrScanned(code)
                })
                ScanOverlayView()
            }
        }
    }

    private func authorizeForm(info: PendingDeviceInfo, deviceName: String, durationSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Authorize this desktop")
                        .font(.headline)
                    Text(deviceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Identity card — full fingerprints so the user can verify
            // bit-for-bit against the desktop's Settings → Device tab.
            VStack(alignment: .leading, spacing: 4) {
                infoRow(label: "Hostname", value: info.hostname.isEmpty ? "—" : info.hostname)
                if !info.osName.isEmpty {
                    infoRow(label: "OS", value: "\(info.osName) \(info.osVersion)".trimmingCharacters(in: .whitespaces))
                }
                if !info.platform.isEmpty { infoRow(label: "Platform", value: info.platform) }
                if !info.appVersion.isEmpty { infoRow(label: "App version", value: info.appVersion) }
                if !info.clientIp.isEmpty { infoRow(label: "Client IP", value: info.clientIp) }
                if !info.binaryFingerprint.isEmpty {
                    infoRow(label: "Binary fingerprint", value: info.binaryFingerprint, mono: true)
                }
                if !info.machineFingerprint.isEmpty {
                    infoRow(label: "Machine fingerprint", value: info.machineFingerprint, mono: true)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1))
            )

            // Device name (editable)
            VStack(alignment: .leading, spacing: 4) {
                Text("Device name").font(.caption).foregroundStyle(.secondary)
                TextField("Device name", text: Binding(
                    get: { deviceName },
                    set: { viewModel.updateDeviceName($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            // Session duration — preset chip row (Android's DURATION_PRESETS)
            VStack(alignment: .leading, spacing: 6) {
                Text("Session duration").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.durationPresets(maxSeconds: info.maxDurationSeconds), id: \.seconds) { preset in
                            let selected = preset.seconds == durationSeconds
                            Button {
                                viewModel.updateDuration(preset.seconds)
                            } label: {
                                Text(preset.label)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(selected ? Color.blue : Color.gray.opacity(0.15))
                                    )
                                    .foregroundColor(selected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Spacer()

            // Action row
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Deny")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await viewModel.approve() }
                } label: {
                    Text("Approve")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func confirmReplaceView(existing: [ExistingDeviceSummary]) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Existing session active")
                .font(.title3)
                .fontWeight(.semibold)
            Text(replaceMessage(existing: existing))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel") {
                    viewModel.cancelReplace()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("End and continue") {
                    Task { await viewModel.confirmReplace() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Authorized")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .foregroundStyle(.red)
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("Scan again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func progressView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private func infoRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func replaceMessage(existing: [ExistingDeviceSummary]) -> String {
        if existing.count == 1 {
            let name = existing.first?.deviceName.isEmpty == false ? existing.first!.deviceName : "another desktop"
            return "\"\(name)\" already has an active session. End it and authorize this new one?"
        } else {
            return "\(existing.count) other desktops have active sessions. End them and authorize this new one?"
        }
    }

    /// Preset session lengths the chip row scrolls through. Clamped to
    /// the vault's `max_duration_seconds` policy.
    static func durationPresets(maxSeconds: Int) -> [(label: String, seconds: Int)] {
        let all: [(String, Int)] = [
            ("1 hour", 60 * 60),
            ("4 hours", 4 * 60 * 60),
            ("8 hours", 8 * 60 * 60),
            ("12 hours", 12 * 60 * 60),
            ("1 day", 24 * 60 * 60),
            ("3 days", 3 * 24 * 60 * 60),
            ("7 days", 7 * 24 * 60 * 60),
            ("14 days", 14 * 24 * 60 * 60),
            ("30 days", 30 * 24 * 60 * 60)
        ]
        let filtered = all.filter { $0.1 <= maxSeconds }
        let chosen = filtered.isEmpty ? [all[0]] : filtered
        return chosen.map { (label: $0.0, seconds: $0.1) }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AuthorizeDeviceView(connectionId: "preview")
    }
}
#endif
