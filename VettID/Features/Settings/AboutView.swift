import SwiftUI

struct AboutView: View {
    @State private var showLicenses = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        List {
            // App Info Section
            Section {
                VStack(spacing: 16) {
                    // App Icon
                    Image("VettIDLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                    // App Name
                    Text("VettID")
                        .font(.title2)
                        .fontWeight(.bold)

                    // Version
                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            // Legal Section
            Section("Legal") {
                Link(destination: URL(string: "https://vettid.dev/terms")!) {
                    AboutLinkRow(icon: "doc.text", title: "Terms of Service")
                }

                Link(destination: URL(string: "https://vettid.dev/privacy")!) {
                    AboutLinkRow(icon: "hand.raised", title: "Privacy Policy")
                }

                Button {
                    showLicenses = true
                } label: {
                    AboutLinkRow(icon: "doc.on.doc", title: "Open Source Licenses")
                }
            }

            // Support Section
            Section("Support") {
                Link(destination: URL(string: "https://vettid.dev/help")!) {
                    AboutLinkRow(icon: "questionmark.circle", title: "Help Center")
                }

                Link(destination: URL(string: "mailto:support@vettid.dev")!) {
                    AboutLinkRow(icon: "envelope", title: "Contact Support")
                }

                Link(destination: URL(string: "https://github.com/vettid")!) {
                    AboutLinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "GitHub")
                }
            }

            // Diagnostics Section
            Section("Diagnostics") {
                HStack {
                    Text("Device ID")
                    Spacer()
                    Text(deviceId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("iOS Version")
                    Spacer()
                    Text(UIDevice.current.systemVersion)
                        .foregroundStyle(.secondary)
                }
            }

            // Footer
            Section {
                VStack(spacing: 8) {
                    Text("Made with care by the VettID team")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\u{00A9} 2024 VettID. All rights reserved.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
    }

    private var deviceId: String {
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "Unknown"
        return String(id.prefix(8)) + "..."
    }
}

// MARK: - About Link Row

struct AboutLinkRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Licenses View

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private let licenses = [
        License(
            name: "Swift Sodium",
            url: "https://github.com/jedisct1/swift-sodium",
            license: "ISC License"
        ),
        License(
            name: "Swift NIO",
            url: "https://github.com/apple/swift-nio",
            license: "Apache 2.0"
        ),
        License(
            name: "NATS.swift",
            url: "https://github.com/nats-io/nats.swift",
            license: "Apache 2.0"
        )
    ]

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("VettID uses the following open source software:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Libraries") {
                    ForEach(licenses) { license in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(license.name)
                                .font(.body)
                                .fontWeight(.medium)

                            Text(license.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let url = URL(string: license.url) {
                                Link(license.url, destination: url)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Open Source Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct License: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let license: String
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AboutView()
    }
}
