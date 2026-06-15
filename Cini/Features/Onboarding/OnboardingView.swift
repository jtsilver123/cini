import SwiftUI

/// First-run flow for a brand-new account. Value props and phone/email/password
/// are collected before this (the pre-auth carousel + sign-up), Beli-style, so
/// onboarding picks up at identity:
///
///   1. Claim your @ — name, username (and who invited you)
///   2. Add a profile photo — its own screen, skippable
///   3. Find your friends — contacts + invite
///   4. Bring your history — Letterboxd ZIP / Apple Notes paste / skip
///   5. Stay in the loop — enable notifications + theater alerts
///   6. Rank your first movie — a poster grid of recognizable titles
///
/// Shown once (per device) when an authenticated user has zero rankings.
struct OnboardingView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    var onFinished: () -> Void

    @State private var step = 0
    @State private var showFindFriends = false
    @State private var username = ""
    @State private var inviterUsername = ""
    /// Set when the user arrived via a friend's invite link — prefilled above.
    @AppStorage("cini.pendingInviter") private var pendingInviter = ""
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
    @State private var notifsEnabled = false
    @State private var theaterZip: String?
    @State private var detectingZip = false

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
            // A driven step switch (not a paged TabView): steps advance only via
            // their buttons, so you can't swipe past a required one (username /
            // photo) or jump ahead to content that isn't ready.
            currentStep
                .id(step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.snappy, value: step)
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
            // Reflect any permissions already granted (re-entering onboarding).
            notifsEnabled = await PushManager.isAuthorized()
            theaterZip = await SupabaseService.shared.homeZip()
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { index in
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
        withAnimation(.snappy) { step = min(step + 1, 5) }
    }

    @ViewBuilder private var currentStep: some View {
        switch step {
        case 0: usernameStep
        case 1: photoStep
        case 2: findFriendsStep
        case 3: importStep
        case 4: permissionsStep
        default: firstRankStep
        }
    }

    // MARK: 3 — Find your friends (Beli puts this in onboarding)

    private var findFriendsStep: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "person.2.fill")
                .font(.system(size: 54)).foregroundStyle(Theme.marquee)
            Text("Find your friends")
                .font(Theme.serif(32)).multilineTextAlignment(.center)
            Text("Cini is better with friends — see their takes before you commit a night, compare taste, and trade recs. Every friend who joins also unlocks a feature for you.")
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Spacer()
            PillButton(title: "Find friends", style: .filled) { showFindFriends = true }
                .padding(.horizontal, 28)
            Button("Maybe later") { advance() }
                .font(.subheadline).foregroundStyle(Theme.gray).padding(.bottom, 30)
        }
        .sheet(isPresented: $showFindFriends, onDismiss: { advance() }) {
            InviteSheet()
        }
    }

    // MARK: 1 — Claim username (name + handle; photo is its own step)

    private var usernameStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Claim your @")
                .font(Theme.serif(34))
            Text("This is how friends find and follow you.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)

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
                // Tapped a friend's invite link → it's already filled in.
                .onAppear { if inviterUsername.isEmpty, !pendingInviter.isEmpty { inviterUsername = pendingInviter } }
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

    // MARK: 2 — Add a profile photo (its own screen, like Beli)

    private var photoStep: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("Add a profile photo")
                .font(Theme.serif(32)).multilineTextAlignment(.center)
            Text("Show the face behind the reviews. You can skip it — your initials stand in until you do.")
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            Button {
                showCropPicker = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(url: avatarURL ?? session.profile?.avatarURL, size: 132,
                               name: displayName.isEmpty ? username : displayName)
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundStyle(Theme.marquee)
                        .background(Circle().fill(Theme.background))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            if isUploadingPhoto { ProgressView().controlSize(.small) }

            Spacer()
            PillButton(title: avatarURL == nil ? "Add a photo" : "Looks good", style: .filled) {
                if avatarURL == nil { showCropPicker = true } else { advance() }
            }
            .padding(.horizontal, 28)
            Button(avatarURL == nil ? "Not now" : "Continue without it") { advance() }
                .font(.subheadline).foregroundStyle(Theme.gray).padding(.bottom, 30)
        }
        .sheet(isPresented: $showCropPicker) {
            CropImagePicker { image in
                Task { await uploadPhoto(image) }
            }
            .ignoresSafeArea()
        }
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
            // uploadAvatar persists avatar_url; refresh so it shows on finish.
            await session.loadProfile()
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
            // Invited by a friend (typed, or carried in from their link):
            // follow each other automatically.
            let typed = inviterUsername.trimmingCharacters(in: .whitespaces)
            let inviter = (typed.isEmpty ? pendingInviter : typed).trimmingCharacters(in: .whitespaces)
            if !inviter.isEmpty {
                let followed = await SupabaseService.shared.redeemInvite(from: inviter)
                pendingInviter = ""
                if followed { ToastCenter.shared.show("You're now following @\(inviter) 🎬") }
            }
            await session.loadProfile()
            advance()
        } catch {
            usernameError = "\(error)".lowercased().contains("duplicate")
                ? "That username is taken — try another."
                : "Couldn't save that username — try another."
        }
    }

    // MARK: 4 — Bring your history

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

    // MARK: 5 — Stay in the loop (notifications + theater alerts)

    private var permissionsStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bell.and.waveform.fill")
                .font(.system(size: 42))
                .foregroundStyle(Theme.gold)
            Text("Stay in the loop")
                .font(Theme.serif(34))
            Text("Two quick things so Cini can reach you.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "bell.badge.fill",
                    title: "Notifications",
                    subtitle: "Friends' ranks, recs sent your way, and replies.",
                    done: notifsEnabled, busy: false
                ) { Task { notifsEnabled = await PushManager.request() } }

                permissionRow(
                    icon: "popcorn.fill",
                    title: "Theater alerts",
                    subtitle: "When a Want to Watch movie is playing near you.",
                    done: theaterZip != nil, busy: detectingZip
                ) { Task { await enableTheaterAlerts() } }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)

            Spacer()
            PillButton(title: "Continue") { advance() }
                .padding(.horizontal, 24)
            Button("Not now") { advance() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 30)
        }
    }

    private func permissionRow(icon: String, title: String, subtitle: String,
                               done: Bool, busy: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Theme.marquee)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.gray)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView()
            } else if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.scoreGreen)
            } else {
                Button("Enable", action: action)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.marquee)
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
    }

    private func enableTheaterAlerts() async {
        detectingZip = true
        defer { detectingZip = false }
        if let zip = try? await LocationZip.shared.currentZip() {
            await SupabaseService.shared.setHomeZip(zip)
            theaterZip = zip
        }
    }

    // MARK: 6 — Rank your first movie

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

            if starters.isEmpty {
                // Posters come from TMDB; if that didn't load (e.g. no network
                // on first launch) don't show a blank grid — point them at search.
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40)).foregroundStyle(Theme.gray)
                Text("Search any title to rank it from the home screen — or jump in and explore first.")
                    .font(.subheadline).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
                Spacer()
            } else {
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
            }

            Button(starters.isEmpty ? "Start exploring" : "I'll explore first") { onFinished() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 24)
        }
    }
}
