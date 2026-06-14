import SwiftUI
import PhotosUI

/// First-run flow for a brand-new account:
///
///   1. Welcome — "Rank, don't rate" (the three circles, the one idea)
///   2. Claim your username (Apple sign-ins arrive as "user_a1b2c3d4")
///   3. Bring your history — Letterboxd ZIP / Apple Notes paste / skip
///   4. Rank your first movie — a poster grid of recognizable titles
///
/// Shown once (per device) when an authenticated user has zero rankings.
struct OnboardingView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    var onFinished: () -> Void

    @State private var step = 0
    @State private var username = ""
    @State private var inviterUsername = ""
    @State private var displayName = ""
    @State private var usernameError: String?
    @State private var saving = false
    @State private var avatarURL: URL?
    @State private var isUploadingPhoto = false
    @State private var showCropPicker = false
    @State private var showImport = false
    @State private var importStartsWithPaste = false
    @State private var starters: [Movie] = []
    @State private var logMovie: Movie?

    private var usernameValid: Bool {
        username.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    private enum Availability { case unknown, checking, available, taken }
    @State private var availability: Availability = .unknown
    @State private var availabilityTask: Task<Void, Never>?

    /// Debounced live check against the username_available RPC.
    private func checkAvailability() {
        availabilityTask?.cancel()
        guard usernameValid else { availability = .unknown; return }
        availability = .checking
        let candidate = username
        availabilityTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let free = await SupabaseService.shared.usernameAvailable(candidate)
            guard candidate == username else { return }
            availability = free ? .available : .taken
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            TabView(selection: $step) {
                welcomeStep.tag(0)
                usernameStep.tag(1)
                importStep.tag(2)
                firstRankStep.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: step)
        }
        .background(Theme.background)
        // Full-screen cover sits above RootTabView's overlay, so onboarding
        // mounts its own toast surface.
        .overlay { ToastOverlay() }
        .sheet(isPresented: $showImport, onDismiss: { advance() }) {
            LetterboxdImportView(startWithPaste: importStartsWithPaste)
        }
        .fullScreenCover(item: $logMovie, onDismiss: {
            if store.watchedCount > 0 { onFinished() }
        }) { movie in
            LogFlowView(movie: movie)
        }
        .swipeDismissesKeyboard()
        .task {
            username = session.profile?.username.hasPrefix("user_") == false
                ? (session.profile?.username ?? "") : ""
            displayName = session.profile?.displayName ?? ""
            starters = ((try? await TMDBService.shared.popular()) ?? [])
                .filter { $0.posterPath != nil }
                .prefix(12).map { $0 }
            for movie in starters { store.cache(movie) }
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.gold : Theme.fill)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .animation(.snappy, value: step)
    }

    private func advance() {
        withAnimation(.snappy) { step = min(step + 1, 3) }
    }

    // MARK: 1 — Welcome

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("cini")
                .font(Theme.display(48))
                .foregroundStyle(Theme.ink)
            Text("EVERY FILM · RANKED")
                .font(.system(size: 11, weight: .bold))
                .tracking(4)
                .foregroundStyle(Theme.gray)

            VStack(spacing: 14) {
                Text("No star ratings. Ever.")
                    .font(.title3.weight(.bold))
                Text("You'll answer one question — **\"Which did you like more?\"** — and Cini builds your perfectly ordered list, with scores that come from your own taste.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 36)

            HStack(spacing: 22) {
                circle(Theme.sentimentLoved, "Liked it")
                circle(Theme.sentimentFine, "Fine")
                circle(Theme.sentimentDisliked, "Didn't")
            }
            .padding(.top, 6)

            Spacer()
            PillButton(title: "Get started") { advance() }
                .padding(.bottom, 36)
        }
    }

    private func circle(_ color: Color, _ label: String) -> some View {
        VStack(spacing: 8) {
            Circle().fill(color).frame(width: 52, height: 52)
            Text(label).font(.caption).foregroundStyle(Theme.gray)
        }
    }

    // MARK: 2 — Claim username

    private var usernameStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Claim your @")
                .font(Theme.serif(34))
            Text("This is how friends find and follow you.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)

            // Photo + name: skipping the photo still shows their initials
            // everywhere, which the avatar previews live as they type.
            VStack(spacing: 8) {
                Button {
                    showCropPicker = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(url: avatarURL ?? session.profile?.avatarURL, size: 84,
                                   name: displayName.isEmpty ? username : displayName)
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.marquee)
                            .background(Circle().fill(Theme.background))
                    }
                }
                .buttonStyle(.plain)
                if isUploadingPhoto {
                    ProgressView().controlSize(.small)
                } else {
                    Text(avatarURL == nil ? "Add a photo" : "Change photo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.gray)
                }
            }
            .sheet(isPresented: $showCropPicker) {
                CropImagePicker { image in
                    Task { await uploadPhoto(image) }
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                TextField("Your name", text: $displayName)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))

                HStack(spacing: 4) {
                    Text("@").foregroundStyle(Theme.gray)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: username) { _, new in
                            username = new.lowercased().filter { $0.isLowercase || $0.isNumber || $0 == "_" }
                            usernameError = nil
                            checkAvailability()
                        }
                    switch availability {
                    case .available:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.scoreGreen)
                    case .taken:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.scoreRed)
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .unknown:
                        EmptyView()
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))

                // Fills as you type toward the 3-character minimum, then
                // turns green — the length rule you can see.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill)
                        Capsule()
                            .fill(username.count >= 3 ? Theme.scoreGreen : Theme.marquee)
                            .frame(width: geo.size.width * min(CGFloat(username.count) / 3, 1))
                    }
                }
                .frame(height: 4)
                .animation(.snappy(duration: 0.2), value: username.count)

                HStack(spacing: 4) {
                    Text("@").foregroundStyle(Theme.gray)
                    TextField("Friend who invited you (optional)", text: $inviterUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
            }
            .padding(.horizontal, 28)

            Text(usernameHint)
                .font(.caption)
                .foregroundStyle(usernameHintColor)

            Spacer()
            PillButton(title: saving ? "Saving…" : "That's me") {
                Task { await saveUsername() }
            }
            .disabled(!usernameValid || availability == .taken || saving)
            .padding(.bottom, 36)
        }
    }

    private var usernameHint: String {
        if let usernameError { return usernameError }
        if !username.isEmpty && username.count < 3 {
            return "At least 3 characters — \(3 - username.count) more to go."
        }
        switch availability {
        case .taken: return "@\(username) is taken — try another."
        case .available: return "@\(username) is yours."
        default: return "3–20 characters: lowercase letters, numbers, underscores."
        }
    }

    private var usernameHintColor: Color {
        if usernameError != nil || availability == .taken { return Theme.scoreRed }
        if availability == .available { return Theme.scoreGreen }
        return Theme.gray
    }

    private func uploadPhoto(_ image: UIImage) async {
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        guard let jpeg = AvatarImage.jpeg(from: image) else {
            ToastCenter.shared.show("Couldn't process that photo — try another.")
            return
        }
        do {
            avatarURL = try await SupabaseService.shared.uploadAvatar(jpeg)
            Haptics.success()
        } catch {
            Haptics.error()
            ToastCenter.shared.show("Photo upload failed — check your connection.")
        }
    }

    private func saveUsername() async {
        saving = true
        defer { saving = false }
        do {
            try await SupabaseService.shared.updateProfile(
                ProfileUpdate(username: username,
                              display_name: displayName.isEmpty ? nil : displayName))
            // Invited by a friend: follow each other automatically.
            let inviter = inviterUsername.trimmingCharacters(in: .whitespaces)
            if !inviter.isEmpty {
                await SupabaseService.shared.redeemInvite(from: inviter)
            }
            await session.loadProfile()
            advance()
        } catch {
            usernameError = "\(error)".lowercased().contains("duplicate")
                ? "That username is taken — try another."
                : "Couldn't save that username — try another."
        }
    }

    // MARK: 3 — Bring your history

    private var importStep: some View {
        VStack(spacing: 18) {
            Spacer()
            ImportHandoffBadge()
            Text("Bring your history")
                .font(Theme.serif(34))
            Text("Already track movies somewhere? Cini queues your whole history so you can rank it — favorites first.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            VStack(spacing: 12) {
                PillButton(title: "Import Letterboxd or IMDb", systemImage: "folder") {
                    importStartsWithPaste = false
                    showImport = true
                }
                PillButton(title: "Paste from Apple Notes", systemImage: "note.text", style: .outlined) {
                    importStartsWithPaste = true
                    showImport = true
                }
            }
            .padding(.top, 6)

            Spacer()
            Button("I'm starting fresh") { advance() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 36)
        }
    }

    // MARK: 4 — Rank your first movie

    private var firstRankStep: some View {
        VStack(spacing: 14) {
            Text("Rank your first movie or show")
                .font(Theme.serif(30))
                .minimumScaleFactor(0.8)
                .padding(.top, 26)
            Text("Pick anything you've seen — your first one takes zero comparisons.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 14) {
                    ForEach(starters) { movie in
                        Button {
                            logMovie = movie
                        } label: {
                            VStack(spacing: 6) {
                                PosterView(url: movie.posterURL, width: 100)
                                Text(movie.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
            }

            Button("I'll explore first") { onFinished() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 24)
        }
    }
}
