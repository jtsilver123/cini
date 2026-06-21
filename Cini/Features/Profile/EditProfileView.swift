import SwiftUI

/// Edit profile, Beli-style: photo up top, identity rows, socials, privacy,
/// then Account settings.
struct EditProfileView: View {
    let profile: Profile
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var avatarURL: URL?
    @State private var isUploadingPhoto = false
    @State private var showCropPicker = false

    @State private var displayName: String
    @State private var username: String
    @State private var bio: String
    @State private var instagram: String
    @State private var tiktok: String
    @State private var x: String
    @State private var letterboxd: String
    @State private var isPrivate: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var usernameTaken = false
    @State private var checkTask: Task<Void, Never>?

    init(profile: Profile, onSaved: @escaping () -> Void = {}) {
        self.profile = profile
        self.onSaved = onSaved
        _displayName = State(initialValue: profile.displayName)
        _username = State(initialValue: profile.username)
        _bio = State(initialValue: profile.bio ?? "")
        _instagram = State(initialValue: profile.instagramHandle ?? "")
        _tiktok = State(initialValue: profile.tiktokHandle ?? "")
        _x = State(initialValue: profile.xHandle ?? "")
        _letterboxd = State(initialValue: profile.letterboxdHandle ?? "")
        _isPrivate = State(initialValue: profile.isPrivate)
    }

    private var usernameValid: Bool {
        let cleaned = username.lowercased()
        return cleaned.count >= 3 && cleaned.count <= 20
            && cleaned.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        AvatarView(url: avatarURL ?? profile.avatarURL, size: 96,
                                   name: profile.displayName.isEmpty ? profile.username : profile.displayName)
                        Button {
                            showCropPicker = true
                        } label: {
                            if isUploadingPhoto {
                                ProgressView()
                            } else {
                                Text("Edit profile photo")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.marquee)
                            }
                        }
                        .disabled(isUploadingPhoto)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                .sheet(isPresented: $showCropPicker) {
                    CropImagePicker { image in
                        Task { await uploadPhoto(image) }
                    }
                    .ignoresSafeArea()
                }

                Section("Identity") {
                    TextField("Display name", text: $displayName)
                    HStack {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: username) { _, _ in
                                usernameTaken = false
                                checkTask?.cancel()
                                guard usernameValid, username.lowercased() != profile.username else { return }
                                let candidate = username.lowercased()
                                checkTask = Task {
                                    try? await Task.sleep(for: .milliseconds(350))
                                    guard !Task.isCancelled else { return }
                                    let free = await SupabaseService.shared.usernameAvailable(candidate)
                                    if candidate == username.lowercased() { usernameTaken = !free }
                                }
                            }
                        if usernameTaken {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.scoreRed)
                                .accessibilityLabel("Username taken")
                        } else if usernameValid && username.lowercased() != profile.username {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.scoreGreen)
                                .accessibilityLabel("Username available")
                        }
                    }
                    if !usernameValid {
                        Text("At least 3 characters (max 20): lowercase letters, numbers, underscores.")
                            .font(.caption)
                            .foregroundStyle(Theme.scoreRed)
                    } else if usernameTaken {
                        Text("That username is taken — try another.")
                            .font(.caption)
                            .foregroundStyle(Theme.scoreRed)
                    }
                    TextField("Bio", text: $bio, axis: .vertical)
                        .lineLimit(2...4)
                        .onChange(of: bio) { _, new in bio = String(new.prefix(160)) }
                }

                Section {
                    socialField("Instagram", text: $instagram)
                    socialField("TikTok", text: $tiktok)
                    socialField("X", text: $x)
                    socialField("Letterboxd", text: $letterboxd)
                } header: {
                    Text("Socials")
                } footer: {
                    Text("Shown on your profile so friends can find you elsewhere.")
                }

                Section {
                    Toggle("Private account", isOn: $isPrivate)
                        .tint(Theme.velvet)
                } footer: {
                    Text("Private accounts only share rankings and activity with approved followers.")
                }

                Section {
                    NavigationLink {
                        AccountSettingsView()
                    } label: {
                        Text("Account settings")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.scoreRed)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(isSaving || !usernameValid || usernameTaken
                              || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func socialField(_ platform: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(platform)
                .foregroundStyle(Theme.gray)
                .frame(width: 92, alignment: .leading)
            Text("@").foregroundStyle(Theme.gray)
            TextField("handle", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func uploadPhoto(_ image: UIImage) async {
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        guard let jpeg = AvatarImage.jpeg(from: image) else {
            errorMessage = "Couldn't process that photo — try another."
            return
        }
        do {
            avatarURL = try await SupabaseService.shared.uploadAvatar(jpeg)
            onSaved()
        } catch {
            errorMessage = "Photo upload failed — check your connection."
        }
    }

    /// Bare handle: strip @, URLs, and whitespace however it was pasted.
    private func clean(_ handle: String) -> String? {
        var h = handle.trimmingCharacters(in: .whitespaces)
        if let last = h.split(separator: "/").last, h.contains("/") { h = String(last) }
        h = h.hasPrefix("@") ? String(h.dropFirst()) : h
        return h.isEmpty ? nil : String(h.prefix(30))
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await SupabaseService.shared.updateProfile(ProfileUpdate(
                username: username.lowercased(),
                display_name: displayName.trimmingCharacters(in: .whitespaces),
                is_private: isPrivate,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                instagram_handle: clean(instagram) ?? "",
                tiktok_handle: clean(tiktok) ?? "",
                x_handle: clean(x) ?? "",
                letterboxd_handle: clean(letterboxd) ?? ""
            ))
            onSaved()
            dismiss()
        } catch {
            let text = "\(error)".lowercased()
            errorMessage = text.contains("duplicate") || text.contains("unique")
                ? "That username is taken — try another."
                : "Couldn't save — check your connection and try again."
        }
    }
}
