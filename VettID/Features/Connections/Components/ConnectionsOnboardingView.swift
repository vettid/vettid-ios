import SwiftUI
import UIKit

// MARK: - Color Extension (Hex Support)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Onboarding Page Model

/// Onboarding page data
struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let description: String
    let iconColor: Color
}

// MARK: - Connections Onboarding Wizard

/// Connection onboarding wizard for first-time users
struct ConnectionsOnboardingWizard: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "person.2.fill",
            title: "Secure Connections",
            description: "Connect with people you trust using end-to-end encryption. Only you and your connection can see your shared data.",
            iconColor: Color(hex: "#6200EA")
        ),
        OnboardingPage(
            icon: "qrcode",
            title: "Easy to Connect",
            description: "Create a QR code invitation and share it with anyone. They scan it, and you're connected instantly.",
            iconColor: Color(hex: "#00BFA5")
        ),
        OnboardingPage(
            icon: "shield.fill",
            title: "You Control Your Data",
            description: "Decide what to share with each connection. Your data is never shared without your explicit consent.",
            iconColor: Color(hex: "#2196F3")
        ),
        OnboardingPage(
            icon: "checkmark.seal.fill",
            title: "Build Trust Over Time",
            description: "Connections start as 'New' and can grow to 'Verified' as you interact. You're always in control.",
            iconColor: Color(hex: "#4CAF50")
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Skip button
            HStack {
                Spacer()
                Button("Skip", action: onSkip)
                    .foregroundStyle(.secondary)
            }
            .padding()

            // Pager
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageContent(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Page indicator
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Capsule()
                        .fill(currentPage == index ? Color.blue : Color(UIColor.systemGray4))
                        .frame(width: currentPage == index ? 24 : 8, height: 8)
                        .animation(.easeInOut, value: currentPage)
                }
            }
            .padding()

            // Navigation buttons
            HStack {
                // Back button
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation {
                            currentPage -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Spacer()
                        .frame(width: 80)
                }

                Spacer()

                // Next/Get Started button
                Button(currentPage == pages.count - 1 ? "Get Started" : "Next") {
                    if currentPage == pages.count - 1 {
                        onComplete()
                    } else {
                        withAnimation {
                            currentPage += 1
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Onboarding Page Content

private struct OnboardingPageContent: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 48) {
            Spacer()

            // Icon
            Circle()
                .fill(page.iconColor.opacity(0.1))
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: page.icon)
                        .font(.system(size: 64))
                        .foregroundStyle(page.iconColor)
                }

            VStack(spacing: 16) {
                // Title
                Text(page.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                // Description
                Text(page.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(24)
    }
}

// MARK: - First Connection Guidance Card

/// First connection guidance card
struct FirstConnectionGuidanceCard: View {
    let onCreateInvitation: () -> Void
    let onScanInvitation: () -> Void
    let onLearnMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "party.popper.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                Text("Make Your First Connection")
                    .font(.headline)
            }

            Text("Connections let you securely share data and communicate with people you trust.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Options
            HStack(spacing: 12) {
                Button(action: onCreateInvitation) {
                    Label("Invite", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onScanInvitation) {
                    Label("Scan", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button("Learn more about connections", action: onLearnMore)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(16)
    }
}

// MARK: - Connection Tips Card

/// Connection tips carousel for onboarding
struct ConnectionTipsCard: View {
    @State private var currentTip = 0

    private let tips = [
        "Tip: Only connect with people you know and trust.",
        "Tip: You can revoke a connection at any time.",
        "Tip: Use tags to organize your connections.",
        "Tip: Mark important connections as favorites for quick access."
    ]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)

            Text(tips[currentTip])
                .font(.caption)
                .foregroundStyle(.secondary)
                .animation(.easeInOut, value: currentTip)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
        .onAppear {
            startTipRotation()
        }
    }

    private func startTipRotation() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            withAnimation {
                currentTip = (currentTip + 1) % tips.count
            }
        }
    }
}

// MARK: - Feature Discovery Tooltip

/// Feature discovery tooltip
struct FeatureDiscoveryTooltip: View {
    let title: String
    let description: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))

            Button("Got it", action: onDismiss)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color(UIColor.systemGray))
        .cornerRadius(12)
    }
}

// MARK: - Help Tooltip

/// Contextual help icon with tooltip
struct HelpTooltip: View {
    let helpText: String
    @State private var showTooltip = false

    var body: some View {
        Button {
            showTooltip.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .popover(isPresented: $showTooltip) {
            Text(helpText)
                .font(.caption)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ConnectionsOnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ConnectionsOnboardingWizard(
                onComplete: {},
                onSkip: {}
            )

            VStack(spacing: 16) {
                FirstConnectionGuidanceCard(
                    onCreateInvitation: {},
                    onScanInvitation: {},
                    onLearnMore: {}
                )

                ConnectionTipsCard()
            }
            .padding()
            .background(Color(UIColor.systemGroupedBackground))
        }
    }
}
#endif
