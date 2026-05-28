import SwiftUI

// MARK: - Confirm Identity View

/// Matches Android `ConfirmIdentityPhaseContent`: shows the identity
/// from the enrollment response with a "what your connections will
/// see" preview, an optional profile-photo picker, and a security
/// note, in a scrollable centered layout.
struct ConfirmIdentityView: View {
    let firstName: String
    let lastName: String
    let email: String
    /// Optional binding so the captured photo survives the
    /// review-screen lifecycle (the view-model holds the photo so the
    /// post-enrollment profile publish can attach it).
    @Binding var photoData: Data?
    let onConfirm: () -> Void
    let onReject: () -> Void

    @State private var showingPhotoPicker = false

    init(
        firstName: String,
        lastName: String,
        email: String,
        photoData: Binding<Data?> = .constant(nil),
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self._photoData = photoData
        self.onConfirm = onConfirm
        self.onReject = onReject
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 12)

                    avatarSection

                    VStack(spacing: 8) {
                        Text("Is this right?")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Here's what we have on file for you")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    identityCard
                    connectionsCard
                    securityNote
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            VStack(spacing: 8) {
                Button(action: onConfirm) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Continue")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Android-parity: full-width text button that goes
                // straight to the IdentityRejected screen — no
                // intermediate confirmation alert. Previously this was
                // a low-contrast subheadline label that read as static
                // text, so users didn't realize it was tappable.
                Button(action: onReject) {
                    Text("Something's wrong")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Sections

    /// Tappable avatar with optional photo + camera badge, matching
    /// Android `ConfirmIdentityPhaseContent`. Hits the existing
    /// `ProfilePhotoPickerSheet` (camera / library / remove) so the
    /// enrollment flow doesn't reinvent the picker UI.
    private var avatarSection: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    showingPhotoPicker = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 112, height: 112)
                        if let data = photoData, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 112, height: 112)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button {
                    showingPhotoPicker = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            if photoData == nil {
                Text("Tap to add a profile photo (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Remove photo") {
                    photoData = nil
                }
                .font(.caption)
            }
        }
        .sheet(isPresented: $showingPhotoPicker) {
            ProfilePhotoPickerSheet { image in
                // ProfilePhotoPickerSheet signals "remove" with a 1×1
                // transparent image — detect that and clear the photo
                // instead of running it through the resize pipeline.
                if image.size.width <= 1 && image.size.height <= 1 {
                    photoData = nil
                } else {
                    photoData = ProfilePhotoHelper.processProfilePhoto(image)
                }
            }
        }
    }

    private var identityCard: some View {
        VStack(spacing: 0) {
            identityRow(icon: "person.text.rectangle", label: "First Name", value: firstName)
            Divider().padding(.vertical, 12)
            identityRow(icon: "person.text.rectangle", label: "Last Name", value: lastName)
            Divider().padding(.vertical, 12)
            identityRow(icon: "envelope.fill", label: "Email", value: email)
        }
        .padding(20)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var connectionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.subheadline)
                Text("What your connections will see")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text("• Your name\n• Your email address\n• Your profile photo (when you add one)")
                .font(.footnote)
            Text("Everything else stays private until you choose to share it from the Data tab.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var securityNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
            Text("This information will be stored securely in your encrypted vault")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func identityRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .fontWeight(.medium)
            }
            Spacer()
        }
    }
}

// MARK: - Preview

#Preview {
    ConfirmIdentityView(
        firstName: "Jane",
        lastName: "Doe",
        email: "jane.doe@example.com",
        onConfirm: {},
        onReject: {}
    )
}
