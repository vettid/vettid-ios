import SwiftUI
import PhotosUI

/// Edit profile view
struct EditProfileView: View {
    let profile: Profile
    let onSave: (Profile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String = ""
    @State private var bio: String = ""
    @State private var location: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarImage: Image?
    @State private var newPhotoData: Data?

    var body: some View {
        NavigationView {
            Form {
                // Avatar section
                Section {
                    HStack {
                        Spacer()
                        avatarPicker
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)

                // Display name
                Section("Display Name") {
                    TextField("Display Name", text: $displayName)
                        .textContentType(.name)
                }

                // Bio
                Section("Bio") {
                    TextEditor(text: $bio)
                        .frame(minHeight: 100)
                }

                // Location
                Section("Location") {
                    TextField("Location (optional)", text: $location)
                        .textContentType(.addressCity)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            displayName = profile.displayName
            bio = profile.bio ?? ""
            location = profile.location ?? ""
        }
        .onChange(of: selectedPhoto) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    avatarImage = Image(uiImage: uiImage)
                    // Process photo for storage
                    newPhotoData = ProfilePhotoHelper.processProfilePhoto(uiImage)
                }
            }
        }
    }

    // MARK: - Avatar Picker

    private var avatarPicker: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            if let avatarImage = avatarImage {
                avatarImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(editOverlay)
            } else if let photoData = profile.photoData,
                      let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(editOverlay)
            } else if let avatarUrl = profile.avatarUrl,
                      let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderAvatar
                }
                .frame(width: 100, height: 100)
                .clipShape(Circle())
                .overlay(editOverlay)
            } else {
                placeholderAvatar
                    .overlay(editOverlay)
            }
        }
    }

    private var placeholderAvatar: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .foregroundColor(.secondary)
            .frame(width: 100, height: 100)
    }

    private var editOverlay: some View {
        Circle()
            .fill(Color.black.opacity(0.4))
            .frame(width: 100, height: 100)
            .overlay {
                Image(systemName: "camera")
                    .font(.title2)
                    .foregroundColor(.white)
            }
    }

    // MARK: - Save

    private func saveProfile() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)

        let updated = Profile(
            guid: profile.guid,
            displayName: trimmedName,
            avatarUrl: profile.avatarUrl,
            bio: trimmedBio.isEmpty ? nil : trimmedBio,
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            email: profile.email,
            photoData: newPhotoData ?? profile.photoData,
            syncedAt: profile.syncedAt,
            lastUpdated: Date()
        )

        onSave(updated)
        dismiss()
    }
}

#if DEBUG
struct EditProfileView_Previews: PreviewProvider {
    static var previews: some View {
        EditProfileView(
            profile: Profile(
                guid: "test",
                displayName: "Test User",
                avatarUrl: nil,
                bio: "Hello world",
                location: "San Francisco",
                email: nil,
                photoData: nil,
                syncedAt: nil,
                lastUpdated: Date()
            ),
            onSave: { _ in }
        )
    }
}
#endif
