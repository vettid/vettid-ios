import SwiftUI

/// Profile view
struct ProfileView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: ProfileViewModel
    @State private var showEditProfile = false
    @State private var showPhotoPicker = false

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: ProfileViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                if viewModel.isLoading {
                    loadingView
                } else if let profile = viewModel.profile {
                    profileContent(profile)
                } else if let error = viewModel.errorMessage {
                    errorView(error)
                }
            }
            .navigationTitle("Profile")
        }
        .sheet(isPresented: $showEditProfile) {
            if let profile = viewModel.profile {
                EditProfileView(profile: profile) { updatedProfile in
                    Task { await viewModel.updateProfile(updatedProfile) }
                }
            }
        }
        .alert("Success", isPresented: .constant(viewModel.successMessage != nil)) {
            Button("OK") { viewModel.clearSuccess() }
        } message: {
            if let message = viewModel.successMessage {
                Text(message)
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil && !viewModel.isLoading)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            ProfilePhotoPickerSheet { image in
                if let photoData = ProfilePhotoHelper.processProfilePhoto(image) {
                    if var profile = viewModel.profile {
                        profile = Profile(
                            guid: profile.guid,
                            displayName: profile.displayName,
                            avatarUrl: profile.avatarUrl,
                            bio: profile.bio,
                            location: profile.location,
                            email: profile.email,
                            photoData: photoData,
                            syncedAt: profile.syncedAt,
                            lastUpdated: Date()
                        )
                        Task { await viewModel.updateProfile(profile) }
                    }
                }
            }
        }
        .task {
            await viewModel.loadProfile()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading profile...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Profile Content

    private func profileContent(_ profile: Profile) -> some View {
        VStack(spacing: 24) {
            // Avatar - show photo data if available, fallback to URL, then placeholder
            ZStack {
                if let photoData = profile.photoData,
                   let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    AsyncImage(url: URL(string: profile.avatarUrl ?? "")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(Circle())
            .onTapGesture {
                showPhotoPicker = true
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.blue)
                    .clipShape(Circle())
            }

            // Display name
            Text(profile.displayName)
                .font(.title)
                .fontWeight(.bold)

            // Email
            if let email = profile.email, !email.isEmpty {
                Label(email, systemImage: "envelope")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Bio
            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Location
            if let location = profile.location, !location.isEmpty {
                Label(location, systemImage: "location")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Actions
            VStack(spacing: 12) {
                Button(action: { showEditProfile = true }) {
                    Label("Edit Profile", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isUpdating)

                Button(action: {
                    Task { await viewModel.publishProfile() }
                }) {
                    if viewModel.isPublishing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Publish to Connections", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isPublishing)
            }
            .padding(.horizontal)

            // Sync status
            if let syncedAt = profile.syncedAt {
                Text("Synced \(syncedAt, style: .relative)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Last updated
            Text("Last updated \(profile.lastUpdated, style: .relative)")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await viewModel.loadProfile() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#if DEBUG
struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView(authTokenProvider: { "test-token" })
    }
}
#endif
