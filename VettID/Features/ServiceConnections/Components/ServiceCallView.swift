import SwiftUI
import AVFoundation

// MARK: - Incoming Call View

/// Full-screen view for incoming service calls
struct IncomingCallView: View {
    let call: IncomingServiceCall
    let onAnswer: () -> Void
    let onDecline: () -> Void

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.9)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                // Verified badge
                verifiedBadge

                Spacer()

                // Service info
                serviceInfo

                // Purpose
                Text(call.purpose)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                // Call actions
                callActions
                    .padding(.bottom, 48)
            }
            .padding()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever()) {
                isPulsing = true
            }
        }
    }

    private var verifiedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
            Text("Verified Call")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.15))
        .cornerRadius(20)
    }

    private var serviceInfo: some View {
        VStack(spacing: 16) {
            // Logo with pulsing ring
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.3), lineWidth: 4)
                    .frame(width: 120, height: 120)
                    .scaleEffect(isPulsing ? 1.2 : 1.0)
                    .opacity(isPulsing ? 0 : 0.8)

                if let logoUrl = call.serviceLogoUrl, let url = URL(string: logoUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        servicePlaceholder
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                } else {
                    servicePlaceholder
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                }
            }

            // Service name
            Text(call.serviceName)
                .font(.title)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            // Agent info
            if let agent = call.agentInfo {
                VStack(spacing: 4) {
                    Text(agent.name)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.9))

                    Text(agent.role)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            // Call type indicator
            HStack(spacing: 8) {
                Image(systemName: call.callType == .video ? "video.fill" : "phone.fill")
                Text(call.callType == .video ? "Video Call" : "Voice Call")
            }
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.6))
        }
    }

    private var servicePlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.3)
            Image(systemName: "building.2.fill")
                .font(.largeTitle)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private var callActions: some View {
        HStack(spacing: 60) {
            // Decline button
            CallActionButton(
                icon: "xmark",
                color: .red,
                label: "Decline",
                action: onDecline
            )

            // Answer button
            CallActionButton(
                icon: call.callType == .video ? "video.fill" : "phone.fill",
                color: .green,
                label: "Answer",
                action: onAnswer
            )
        }
    }
}

// MARK: - Active Call View

/// View for an active service call
struct ActiveCallView: View {
    @ObservedObject var callManager: ServiceCallManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Background
            if callManager.callType == .video {
                videoBackground
            } else {
                Color.black.opacity(0.95)
                    .ignoresSafeArea()
            }

            VStack {
                // Top bar
                topBar

                Spacer()

                // Center content (for audio calls)
                if callManager.callType == .audio {
                    audioCallContent
                }

                Spacer()

                // Bottom controls
                callControls
                    .padding(.bottom, 32)
            }
            .padding()
        }
    }

    private var videoBackground: some View {
        ZStack {
            // Remote video (full screen)
            Color.black
                .ignoresSafeArea()

            // Placeholder for WebRTC video
            if !callManager.isRemoteVideoActive {
                VStack {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.5))
                    Text("Video paused")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            // Local video (picture-in-picture)
            VStack {
                HStack {
                    Spacer()
                    localVideoPreview
                        .frame(width: 120, height: 160)
                        .cornerRadius(12)
                        .padding()
                }
                Spacer()
            }
        }
    }

    private var localVideoPreview: some View {
        ZStack {
            Color.gray.opacity(0.3)

            if callManager.isVideoEnabled {
                // Placeholder for local video track
                Color.black
            } else {
                VStack {
                    Image(systemName: "video.slash.fill")
                        .foregroundColor(.white.opacity(0.5))
                    Text("Camera off")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            // Service badge
            HStack(spacing: 8) {
                if let logoUrl = callManager.serviceLogoUrl, let url = URL(string: logoUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(callManager.serviceName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("Verified")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.5))
            .cornerRadius(20)

            Spacer()

            // Duration
            Text(callManager.formattedDuration)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.5))
                .cornerRadius(16)
        }
    }

    private var audioCallContent: some View {
        VStack(spacing: 24) {
            // Service logo
            if let logoUrl = callManager.serviceLogoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "building.2.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.5))
                    )
            }

            Text(callManager.serviceName)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            // Audio visualization placeholder
            HStack(spacing: 4) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green)
                        .frame(width: 4, height: callManager.isMuted ? 8 : CGFloat.random(in: 8...32))
                        .animation(.easeInOut(duration: 0.2), value: callManager.isMuted)
                }
            }
        }
    }

    private var callControls: some View {
        HStack(spacing: 32) {
            // Mute
            CallControlButton(
                icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: callManager.isMuted,
                label: callManager.isMuted ? "Unmute" : "Mute"
            ) {
                callManager.toggleMute()
            }

            // Video (if video call)
            if callManager.callType == .video {
                CallControlButton(
                    icon: callManager.isVideoEnabled ? "video.fill" : "video.slash.fill",
                    isActive: !callManager.isVideoEnabled,
                    label: callManager.isVideoEnabled ? "Stop Video" : "Start Video"
                ) {
                    callManager.toggleVideo()
                }
            }

            // Speaker
            CallControlButton(
                icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                isActive: callManager.isSpeakerOn,
                label: callManager.isSpeakerOn ? "Speaker" : "Phone"
            ) {
                callManager.toggleSpeaker()
            }

            // End call
            CallControlButton(
                icon: "phone.down.fill",
                color: .red,
                label: "End"
            ) {
                callManager.endCall()
                dismiss()
            }
        }
    }
}

// MARK: - Call Action Button (Large)

struct CallActionButton: View {
    let icon: String
    var color: Color = .white
    let label: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(.white)
                    .frame(width: 72, height: 72)
                    .background(color)
                    .clipShape(Circle())
            }

            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

// MARK: - Call Control Button (Small)

struct CallControlButton: View {
    let icon: String
    var isActive: Bool = false
    var color: Color? = nil
    let label: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color != nil ? .white : (isActive ? .black : .white))
                    .frame(width: 56, height: 56)
                    .background(color ?? (isActive ? Color.white : Color.white.opacity(0.2)))
                    .clipShape(Circle())
            }

            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: - Call Types

/// Incoming service call
struct IncomingServiceCall: Codable, Identifiable {
    let id: String
    let serviceId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let domainVerified: Bool
    let callType: ServiceCallType
    let purpose: String
    let agentInfo: CallAgentInfo?
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "call_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case domainVerified = "domain_verified"
        case callType = "call_type"
        case purpose
        case agentInfo = "agent_info"
        case receivedAt = "received_at"
    }
}

/// Call type
enum ServiceCallType: String, Codable {
    case audio
    case video
}

/// Agent info for call
struct CallAgentInfo: Codable {
    let name: String
    let role: String
    let photoUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case role
        case photoUrl = "photo_url"
    }
}

// MARK: - Service Call Manager

/// Manages active service call state
@MainActor
class ServiceCallManager: ObservableObject {
    @Published var callType: ServiceCallType
    @Published var serviceName: String
    @Published var serviceLogoUrl: String?
    @Published var isConnected = false
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var isSpeakerOn = false
    @Published var isRemoteVideoActive = true
    @Published private(set) var duration: TimeInterval = 0

    private var durationTimer: Timer?

    var formattedDuration: String {
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d", minutes, seconds)
    }

    init(callType: ServiceCallType, serviceName: String, serviceLogoUrl: String?) {
        self.callType = callType
        self.serviceName = serviceName
        self.serviceLogoUrl = serviceLogoUrl
    }

    func startCall() {
        isConnected = true
        startDurationTimer()

        // In production, initialize WebRTC here
        #if DEBUG
        print("[ServiceCall] Starting \(callType) call with \(serviceName)")
        #endif
    }

    func endCall() {
        isConnected = false
        durationTimer?.invalidate()
        durationTimer = nil

        // In production, close WebRTC connection
        #if DEBUG
        print("[ServiceCall] Ended call after \(formattedDuration)")
        #endif
    }

    func toggleMute() {
        isMuted.toggle()
        // In production, mute audio track
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
        // In production, enable/disable video track
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        // In production, switch audio route
    }

    private func startDurationTimer() {
        duration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.duration += 1
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
struct IncomingCallView_Previews: PreviewProvider {
    static var previews: some View {
        IncomingCallView(
            call: IncomingServiceCall(
                id: "call-123",
                serviceId: "service-123",
                serviceName: "Example Bank",
                serviceLogoUrl: nil,
                domainVerified: true,
                callType: .video,
                purpose: "Regarding your recent account inquiry",
                agentInfo: CallAgentInfo(
                    name: "Sarah Johnson",
                    role: "Customer Support",
                    photoUrl: nil
                ),
                receivedAt: Date()
            ),
            onAnswer: {},
            onDecline: {}
        )
    }
}

struct ActiveCallView_Previews: PreviewProvider {
    static var previews: some View {
        ActiveCallView(
            callManager: ServiceCallManager(
                callType: .video,
                serviceName: "Example Bank",
                serviceLogoUrl: nil
            )
        )
    }
}
#endif
