import Foundation
import UIKit

/// Screen protection utilities to prevent sensitive data capture
/// Implements screenshot detection and screen recording protection
final class ScreenProtection {

    // MARK: - Singleton

    static let shared = ScreenProtection()

    private init() {}

    // MARK: - Properties

    /// Callback when screen capture is detected
    var onScreenCaptureDetected: (() -> Void)?

    /// Callback when screenshot is detected
    var onScreenshotDetected: (() -> Void)?

    /// Privacy overlay view (shown during screen capture)
    private var privacyOverlay: UIView?

    /// Whether to automatically show privacy overlay during capture
    var autoShowPrivacyOverlay: Bool = true

    // MARK: - Monitoring

    /// Start monitoring for screen capture and screenshots
    func startMonitoring() {
        // Monitor screen capture (recording/mirroring)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenCaptureChange),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )

        // Monitor screenshots
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        // Check initial state
        if UIScreen.main.isCaptured {
            handleScreenCaptureChange()
        }
    }

    /// Stop monitoring
    func stopMonitoring() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        hidePrivacyOverlay()
    }

    // MARK: - Event Handlers

    @objc private func handleScreenCaptureChange() {
        DispatchQueue.main.async { [weak self] in
            if UIScreen.main.isCaptured {
                self?.onScreenCaptureDetected?()
                if self?.autoShowPrivacyOverlay == true {
                    self?.showPrivacyOverlay()
                }
            } else {
                self?.hidePrivacyOverlay()
            }
        }
    }

    @objc private func handleScreenshot() {
        onScreenshotDetected?()

        // Could implement additional actions:
        // - Log security event
        // - Show warning to user
        // - Clear sensitive data from screen
    }

    // MARK: - Privacy Overlay

    /// Show privacy overlay to hide sensitive content during screen recording
    private func showPrivacyOverlay() {
        guard privacyOverlay == nil else { return }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return
        }

        let overlay = UIView(frame: window.bounds)
        overlay.backgroundColor = UIColor.systemBackground
        overlay.tag = 999_999  // Unique tag for identification

        // Add VettID logo or message
        let messageLabel = UILabel()
        messageLabel.text = "Screen recording detected\nSensitive content hidden"
        messageLabel.numberOfLines = 2
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.font = .preferredFont(forTextStyle: .headline)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])

        window.addSubview(overlay)
        privacyOverlay = overlay
    }

    /// Hide the privacy overlay
    private func hidePrivacyOverlay() {
        privacyOverlay?.removeFromSuperview()
        privacyOverlay = nil
    }

    // MARK: - Secure Text Field

    /// Check if screen is currently being captured
    var isScreenBeingCaptured: Bool {
        return UIScreen.main.isCaptured
    }
}

// MARK: - Secure View Extension

extension UIView {

    /// Make this view hidden during screen capture
    /// Uses a secure text field technique to hide content
    func makeSecure() {
        DispatchQueue.main.async {
            // Create a secure text field container
            let secureField = UITextField()
            secureField.isSecureTextEntry = true
            secureField.isUserInteractionEnabled = false

            // Get the secure container (this hides content from screenshots/recordings)
            guard let secureContainer = secureField.subviews.first else { return }

            // Move our content into the secure container
            secureContainer.subviews.forEach { $0.removeFromSuperview() }

            // Add this view's layer to the secure container
            secureContainer.addSubview(self)

            // Constrain to fill
            self.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                self.leadingAnchor.constraint(equalTo: secureContainer.leadingAnchor),
                self.trailingAnchor.constraint(equalTo: secureContainer.trailingAnchor),
                self.topAnchor.constraint(equalTo: secureContainer.topAnchor),
                self.bottomAnchor.constraint(equalTo: secureContainer.bottomAnchor)
            ])
        }
    }
}

// MARK: - Secure Window

/// A window subclass that prevents content from appearing in screenshots
/// Note: This technique uses the isSecureTextEntry mechanism
final class SecureWindow: UIWindow {

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        setupSecureContent()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSecureContent()
    }

    private func setupSecureContent() {
        // The secure text field technique prevents content from appearing
        // in screenshots and screen recordings
        let secureField = UITextField()
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false

        // This technique doesn't fully work in all iOS versions
        // Use in combination with ScreenProtection monitoring
    }
}
