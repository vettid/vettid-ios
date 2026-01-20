import SwiftUI
import UIKit
import MessageUI

// MARK: - Share Method

enum ShareMethod: CaseIterable, Identifiable {
    case clipboard
    case messages
    case email
    case airdrop
    case systemShare

    var id: Self { self }

    var title: String {
        switch self {
        case .clipboard: return "Copy Link"
        case .messages: return "Messages"
        case .email: return "Email"
        case .airdrop: return "AirDrop"
        case .systemShare: return "More Options"
        }
    }

    var icon: String {
        switch self {
        case .clipboard: return "doc.on.doc"
        case .messages: return "message.fill"
        case .email: return "envelope.fill"
        case .airdrop: return "airplayaudio"
        case .systemShare: return "square.and.arrow.up"
        }
    }

    var color: Color {
        switch self {
        case .clipboard: return .blue
        case .messages: return .green
        case .email: return .orange
        case .airdrop: return .blue
        case .systemShare: return .purple
        }
    }
}

// MARK: - Share Invitation Sheet

/// Enhanced invitation sharing sheet with multiple methods
struct ShareInvitationSheet: View {
    let invitationUrl: String
    let qrCodeData: String?
    let onDismiss: () -> Void

    @State private var copiedToClipboard = false
    @State private var showingActivitySheet = false
    @State private var showingEmailComposer = false
    @State private var showingMessageComposer = false
    @State private var selectedMethod: ShareMethod?

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // QR Code display
                if let qrCodeData = qrCodeData {
                    QRCodeDisplayView(data: qrCodeData)
                        .frame(width: 200, height: 200)
                        .padding()
                }

                // Share methods
                VStack(alignment: .leading, spacing: 16) {
                    Text("Share via")
                        .font(.headline)
                        .padding(.horizontal)

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(ShareMethod.allCases) { method in
                            ShareMethodButton(
                                method: method,
                                isSelected: selectedMethod == method
                            ) {
                                handleShareMethod(method)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                // Invitation link
                VStack(alignment: .leading, spacing: 8) {
                    Text("Invitation Link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    HStack {
                        Text(invitationUrl)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button {
                            copyToClipboard()
                        } label: {
                            Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copiedToClipboard ? .green : .blue)
                        }
                    }
                    .padding(12)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                // Instructions
                Text("The recipient can scan the QR code or tap the link to connect with you securely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Share Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .sheet(isPresented: $showingActivitySheet) {
            ActivityViewController(activityItems: [invitationUrl])
        }
        .sheet(isPresented: $showingEmailComposer) {
            if MFMailComposeViewController.canSendMail() {
                MailComposeView(
                    subject: "VettID Connection Invitation",
                    body: createEmailBody(),
                    isPresented: $showingEmailComposer
                )
            }
        }
        .sheet(isPresented: $showingMessageComposer) {
            if MFMessageComposeViewController.canSendText() {
                MessageComposeView(
                    body: createMessageBody(),
                    isPresented: $showingMessageComposer
                )
            }
        }
    }

    private func handleShareMethod(_ method: ShareMethod) {
        selectedMethod = method

        switch method {
        case .clipboard:
            copyToClipboard()
        case .messages:
            if MFMessageComposeViewController.canSendText() {
                showingMessageComposer = true
            } else {
                // Fall back to system share
                showingActivitySheet = true
            }
        case .email:
            if MFMailComposeViewController.canSendMail() {
                showingEmailComposer = true
            } else {
                // Fall back to system share
                showingActivitySheet = true
            }
        case .airdrop, .systemShare:
            showingActivitySheet = true
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = invitationUrl
        copiedToClipboard = true

        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedToClipboard = false
            selectedMethod = nil
        }
    }

    private func createEmailBody() -> String {
        """
        Hi,

        I'd like to connect with you on VettID for secure communication.

        Click this link to accept my invitation:
        \(invitationUrl)

        VettID uses end-to-end encryption to keep our conversations private.

        See you there!
        """
    }

    private func createMessageBody() -> String {
        "I'd like to connect with you on VettID! Tap this link to accept: \(invitationUrl)"
    }
}

// MARK: - Share Method Button

private struct ShareMethodButton: View {
    let method: ShareMethod
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(method.color.opacity(0.15))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: method.icon)
                            .font(.title2)
                            .foregroundStyle(method.color)
                    }

                Text(method.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .scaleEffect(isSelected ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

// MARK: - QR Code Display View

struct QRCodeDisplayView: View {
    let data: String

    var body: some View {
        if let image = generateQRCode(from: data) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .background(Color.white)
                .cornerRadius(12)
        } else {
            Rectangle()
                .fill(Color(UIColor.systemGray5))
                .overlay {
                    Text("QR Code")
                        .foregroundStyle(.secondary)
                }
                .cornerRadius(12)
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")

            if let outputImage = filter.outputImage {
                let transform = CGAffineTransform(scaleX: 10, y: 10)
                let scaledImage = outputImage.transformed(by: transform)
                let context = CIContext()
                if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                    return UIImage(cgImage: cgImage)
                }
            }
        }
        return nil
    }
}

// MARK: - UIKit Bridges

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct MailComposeView: UIViewControllerRepresentable {
    let subject: String
    let body: String
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposeView

        init(_ parent: MailComposeView) {
            self.parent = parent
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.isPresented = false
        }
    }
}

struct MessageComposeView: UIViewControllerRepresentable {
    let body: String
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.body = body
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let parent: MessageComposeView

        init(_ parent: MessageComposeView) {
            self.parent = parent
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            parent.isPresented = false
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ShareInvitationSheet_Previews: PreviewProvider {
    static var previews: some View {
        ShareInvitationSheet(
            invitationUrl: "https://vettid.app/connect/abc123xyz",
            qrCodeData: "vettid://connect?code=abc123xyz",
            onDismiss: {}
        )
    }
}
#endif
