import SwiftUI

// MARK: - Outgoing Call View

/// Phase 4.2 — shown while we're dialing a peer. Observes
/// CallCoordinator.callState and dismisses up the chain when the call
/// connects (parent swaps in ActiveCallView), is declined, or fails.
struct OutgoingCallView: View {
    @ObservedObject var coordinator: CallCoordinator
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            CallBackgroundGradient()

            VStack(spacing: 24) {
                Spacer()

                avatar
                    .padding(.bottom, 8)

                Text(coordinator.currentCall?.peerDisplayName ?? "Calling…")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                // Cancel — red end-call button. Routes to CallCoordinator.endCall.
                Button {
                    Task { try? await coordinator.endCall(); onCancel() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 72, height: 72)
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 56)
                .accessibilityLabel("End call")
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        let name = coordinator.currentCall?.peerDisplayName ?? "?"
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [.blue.opacity(0.45), .purple.opacity(0.45)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 140, height: 140)
            Text(initials(from: name))
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var statusLine: String {
        switch coordinator.callState {
        case .connecting:   return "Calling…"
        case .ringing:      return "Ringing…"
        case .connected:    return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .failed:       return "Call failed"
        case .idle:         return ""
        }
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

// MARK: - Incoming Call View

/// Phase 4.2 — full-screen ringing UI for an inbound call. Shown at
/// app root via ContentView when CallCoordinator.callState becomes
/// `.ringing` with an incoming direction.
struct IncomingCallView: View {
    @ObservedObject var coordinator: CallCoordinator
    let onAnswered: () -> Void
    let onDeclined: () -> Void

    var body: some View {
        ZStack {
            CallBackgroundGradient()

            VStack(spacing: 24) {
                Spacer()

                Text("Incoming call")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))

                IncomingAvatar(name: coordinator.currentCall?.peerDisplayName ?? "?")

                Text(coordinator.currentCall?.peerDisplayName ?? "Caller")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                Text(coordinator.currentCall?.callType == .video ? "Video call" : "Audio call")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                HStack(spacing: 80) {
                    // Decline
                    Button {
                        Task {
                            try? await coordinator.rejectCall(reason: .declined)
                            onDeclined()
                        }
                    } label: {
                        ZStack {
                            Circle().fill(.red).frame(width: 72, height: 72)
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityLabel("Decline call")

                    // Answer
                    Button {
                        Task {
                            try? await coordinator.answerCall()
                            onAnswered()
                        }
                    } label: {
                        ZStack {
                            Circle().fill(.green).frame(width: 72, height: 72)
                            Image(systemName: "phone.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityLabel("Answer call")
                }
                .padding(.bottom, 56)
            }
        }
    }
}

// MARK: - Active Call View

/// Phase 4.2 — render-during-call surface. Hosts the remote-video
/// placeholder (real RTCVideoTrack lands in Phase 4.1 follow-up) plus
/// the control row (mute, video toggle, speaker, camera flip, end).
struct ActiveCallView: View {
    @ObservedObject var coordinator: CallCoordinator
    let onEnded: () -> Void

    @State private var callStart: Date = Date()

    var body: some View {
        ZStack {
            // Black-ish background; once WebRTC framework lands, the
            // remote RTCVideoTrack renders here behind the overlay.
            Color.black.ignoresSafeArea()

            VStack {
                // Peer name + timer
                VStack(spacing: 4) {
                    Text(coordinator.currentCall?.peerDisplayName ?? "Call")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(elapsedString)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
                .padding(.top, 32)

                Spacer()

                // Avatar fallback when video is off / not yet wired.
                avatar

                Spacer()

                // Controls
                controlsRow

                // End-call (red)
                Button {
                    Task { try? await coordinator.endCall(); onEnded() }
                } label: {
                    ZStack {
                        Circle().fill(.red).frame(width: 72, height: 72)
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 56)
                .accessibilityLabel("End call")
            }
        }
        .onAppear { callStart = Date() }
    }

    private var elapsedString: String {
        let seconds = Int(Date().timeIntervalSince(callStart))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private var avatar: some View {
        let name = coordinator.currentCall?.peerDisplayName ?? "?"
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [.blue.opacity(0.5), .purple.opacity(0.5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 180, height: 180)
            Text(initials(from: name))
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 24) {
            CallControlButton(
                systemImage: coordinator.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                label: coordinator.isAudioMuted ? "Unmute" : "Mute",
                isActive: coordinator.isAudioMuted
            ) { coordinator.toggleMute() }

            if coordinator.currentCall?.callType == .video {
                CallControlButton(
                    systemImage: coordinator.isVideoEnabled ? "video.fill" : "video.slash.fill",
                    label: coordinator.isVideoEnabled ? "Video off" : "Video on",
                    isActive: !coordinator.isVideoEnabled
                ) { coordinator.toggleVideo() }

                CallControlButton(
                    systemImage: "camera.rotate.fill",
                    label: "Flip"
                ) { coordinator.switchCamera() }
            }

            CallControlButton(
                systemImage: coordinator.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Speaker",
                isActive: coordinator.isSpeakerOn
            ) { coordinator.toggleSpeaker() }
        }
        .padding(.bottom, 16)
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

// MARK: - Shared Components

private struct CallBackgroundGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.08, blue: 0.20),
                Color(red: 0.05, green: 0.05, blue: 0.10)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct IncomingAvatar: View {
    let name: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 4)
                .frame(width: 160, height: 160)
                .scaleEffect(pulse ? 1.15 : 1.0)
                .opacity(pulse ? 0 : 1)
                .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)

            Circle()
                .fill(LinearGradient(
                    colors: [.blue.opacity(0.45), .purple.opacity(0.45)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 140, height: 140)
            Text(initials(from: name))
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .onAppear { pulse = true }
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

private struct CallControlButton: View {
    let systemImage: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.white : Color.white.opacity(0.18))
                        .frame(width: 56, height: 56)
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isActive ? .black : .white)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Call Failed

/// Brief surface shown when callState lands on `.failed` before the
/// coordinator clears the call. Mostly a placeholder for a future
/// retry / error-detail UI.
struct CallFailedView: View {
    @ObservedObject var coordinator: CallCoordinator

    var body: some View {
        ZStack {
            CallBackgroundGradient()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.red.opacity(0.85))
                Text("Call failed")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text(coordinator.currentCall?.peerDisplayName ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

// MARK: - Preview

#Preview("Outgoing") {
    OutgoingCallView(coordinator: CallCoordinator.shared, onCancel: {})
}

#Preview("Incoming") {
    IncomingCallView(coordinator: CallCoordinator.shared, onAnswered: {}, onDeclined: {})
}

#Preview("Active") {
    ActiveCallView(coordinator: CallCoordinator.shared, onEnded: {})
}
