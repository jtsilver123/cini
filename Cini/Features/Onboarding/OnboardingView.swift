import SwiftUI

/// First-run flow for a brand-new account. Value props and phone/email/password
/// are collected before this (the pre-auth carousel + sign-up), Beli-style, so
/// onboarding picks up at the welcome:
///
///   0. You're in! — meet Jake, the friend everyone starts following
///   1. What's your name? — first + last (how friends see you)
///   2. Your username — the @handle (and who invited you)
///   3. Add a profile photo — its own screen, skippable
///   4. Find your friends — contacts + invite
///   5. Bring your history — Letterboxd ZIP / Apple Notes paste / skip
///   6. Stay in the loop — enable notifications + theater alerts
///   7. Rank your first movie — a poster grid of iconic titles
///
/// Shown once (per account) when an authenticated user has zero rankings.
struct OnboardingView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    var onFinished: () -> Void

    @State private var step = 0
    @State private var showFindFriends = false
    @State private var showSkipFriendsNudge = false
    @State private var username = ""
    @State private var inviterUsername = ""
    /// Set when the user arrived via a friend's invite link — prefilled above.
    @AppStorage("cini.pendingInviter") private var pendingInviter = ""
    @State private var firstName = ""
    @State private var lastName = ""
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
    /// The founder everyone auto-follows — introduced on the "You're in!" screen
    /// (Beli's "Judy"). Fetched so the avatar/name stay accurate.
    @State private var founder: Profile?
    @State private var showFounderInfo = false
    @State private var showInviterEntry = false
    @State private var inviterDraft = ""
    /// Which text field owns the keyboard — lets us raise it as a text step
    /// appears and lower it cleanly *before* a transition (instead of letting
    /// the keyboard collapse mid-slide, which felt abrupt).
    private enum Field: Hashable { case firstName, lastName, username }
    @FocusState private var focus: Field?
    private static let founderID = UUID(uuidString: "c8a4e18e-7b5b-405d-bb74-6e1e79702f60")!

    private var usernameValid: Bool {
        username.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    /// First + last combined into the single display name we store.
    private var fullName: String {
        [firstName, lastName].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
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
            // The "You're in!" welcome (step 0) is a clean moment — no bar.
            if step > 0 { topBar }
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
        // Don't auto-finish after one rank — return to the grid so they can
        // rank as many as they like. The "Done" button below ends onboarding.
        .fullScreenCover(item: $logMovie) { movie in
            LogFlowView(movie: movie)
        }
        .swipeDismissesKeyboard()
        .task {
            username = session.profile?.username.hasPrefix("user_") == false
                ? (session.profile?.username ?? "") : ""
            // Pre-fill first/last from any existing display name.
            let dn = (session.profile?.displayName ?? "").trimmingCharacters(in: .whitespaces)
            if !dn.isEmpty {
                let parts = dn.split(separator: " ", maxSplits: 1).map(String.init)
                firstName = parts.first ?? ""
                lastName = parts.count > 1 ? parts[1] : ""
            }
            // Iconic, instantly-recognizable films so the first rank is easy —
            // Godfather, Star Wars, Avengers, etc. (curated TMDB ids, fetched +
            // validated in parallel) rather than whatever's merely trending.
            let iconicIDs = [238, 278, 155, 680, 11, 27205, 603, 13, 157336,
                             597, 329, 120, 24428, 550, 496243, 98]
            let fetched = await withTaskGroup(of: Movie?.self) { group in
                for id in iconicIDs {
                    group.addTask { try? await TMDBService.shared.details(for: id) }
                }
                var out: [Movie] = []
                for await m in group where (m?.posterPath != nil) { if let m { out.append(m) } }
                return out
            }
            let order = Dictionary(uniqueKeysWithValues: iconicIDs.enumerated().map { ($1, $0) })
            starters = fetched.sorted { (order[$0.tmdbID] ?? 99) < (order[$1.tmdbID] ?? 99) }
            for movie in starters { store.cache(movie) }
            // Reflect any permissions already granted (re-entering onboarding).
            notifsEnabled = await PushManager.isAuthorized()
            theaterZip = await SupabaseService.shared.homeZip()
            founder = try? await SupabaseService.shared.profile(id: Self.founderID).asProfile
        }
    }

    /// A back chevron (so a typo'd name/username is fixable) above seven
    /// progress segments for the seven data steps (1–7).
    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button { goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 12)
            HStack(spacing: 6) {
                ForEach(1..<8, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.gold : Theme.fill)
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 28)
            .animation(.snappy, value: step)
        }
        .padding(.top, 8)
    }

    /// Advance a step. If the keyboard is up, lower it first and let it settle
    /// before the slide so the two animations don't fight (the "abrupt" feel).
    private func advance() {
        guard focus != nil else {
            withAnimation(.snappy) { step = min(step + 1, 7) }
            return
        }
        focus = nil
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.snappy) { step = min(step + 1, 7) }
        }
    }

    private func goBack() {
        focus = nil
        withAnimation(.snappy) { step = max(step - 1, 0) }
    }

    /// Raise the keyboard for a text step once its slide-in has settled.
    private func focusAfterTransition(_ field: Field) {
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            focus = field
        }
    }

    @ViewBuilder private var currentStep: some View {
        switch step {
        case 0: youreInStep
        case 1: nameStep
        case 2: usernameStep
        case 3: photoStep
        case 4: findFriendsStep
        case 5: importStep
        case 6: permissionsStep
        default: firstRankStep
        }
    }

    // MARK: 0 — You're in! (meet Jake, the friend everyone starts with)

    private var founderFirstName: String {
        (founder?.displayName)
            .flatMap { $0.isEmpty ? nil : $0.split(separator: " ").first.map(String.init) } ?? "Jake"
    }

    private var youreInStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("You're in!")
                .font(Theme.serif(40)).foregroundStyle(Theme.ink)
            AvatarView(url: founder?.avatarURL, size: 132,
                       name: founder?.displayName ?? "Jake Silver")
            VStack(spacing: 8) {
                Text("\(founderFirstName) will help you find your next favorite")
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
                Button("Who's \(founderFirstName)?") { showFounderInfo = true }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.marquee)
            }
            Spacer()
            PillButton(title: "Get started") { advance() }
                .padding(.horizontal, 28)
            Button("Invited by someone else?") { inviterDraft = inviterUsername; showInviterEntry = true }
                .font(.subheadline).foregroundStyle(Theme.gray).padding(.bottom, 30)
        }
        // Branded bottom sheets — system alerts/dialogs were rendering as a
        // standard centered iOS alerts (the system confirmationDialog had been
        // rendering as a misplaced popover bubble).
        .alert("Who's \(founderFirstName)?", isPresented: $showFounderInfo) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("\(founderFirstName) founded Cini and lives for movies. Everyone starts out following \(founderFirstName), so your feed has great picks from day one — you can unfollow any time.")
        }
        .alert("Who invited you?", isPresented: $showInviterEntry) {
            TextField("their username", text: $inviterDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") {
                inviterUsername = inviterDraft
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "@", with: "")
            }
            Button("Cancel", role: .cancel) { inviterDraft = "" }
        } message: {
            Text("Enter their username and you'll follow each other automatically once you finish.")
        }
    }

    // MARK: 4 — Find your friends (Beli puts this in onboarding)

    private var findFriendsStep: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "person.2.fill")
                .font(.system(size: 54)).foregroundStyle(Theme.marquee)
            Text("Find your friends")
                .font(Theme.serif(32)).multilineTextAlignment(.center)
            Text("Cini is better with friends. Every friend who joins also unlocks a feature for you.")
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 16) {
                friendBenefit("eye.fill", "See what they think before you watch")
                friendBenefit("percent", "See how your taste matches theirs")
                friendBenefit("paperplane.fill", "Swap movie picks")
            }
            .padding(.horizontal, 40)
            .padding(.top, 6)

            Spacer()
            PillButton(title: "Find friends", style: .filled) { showFindFriends = true }
                .padding(.horizontal, 28)
            Button("Maybe later") { showSkipFriendsNudge = true }
                .font(.subheadline).foregroundStyle(Theme.gray).padding(.bottom, 30)
        }
        .sheet(isPresented: $showFindFriends, onDismiss: { advance() }) {
            // Pull the contact list up immediately instead of showing a button.
            InviteSheet(autoFindContacts: true)
        }
        // Beli-style nudge: one more chance to invite before skipping. A
        // standard centered alert (the system confirmationDialog had been
        // rendering as a misplaced popover bubble).
        .alert("Cini is so much better with friends", isPresented: $showSkipFriendsNudge) {
            Button("Invite friends") {
                // Let the alert dismiss before presenting the contacts sheet.
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    showFindFriends = true
                }
            }
            Button("Skip for now", role: .cancel) { advance() }
        } message: {
            Text("Invite one friend to unlock a feature. The moment they join, you'll see what they're watching.")
        }
    }

    private func friendBenefit(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .frame(width: 26)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
    }

    // MARK: 1 — What's your name? (first + last, like Beli)

    private var nameStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("What's your name?")
                .font(Theme.serif(34))
            Text("This is how friends will see you.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)

            VStack(spacing: 10) {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($focus, equals: .firstName)
                    .onSubmit { focus = .lastName }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focus, equals: .lastName)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
            }
            .padding(.horizontal, 28)

            Spacer()
            PillButton(title: "Continue") { advance() }
                .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.bottom, 36)
        }
        .onAppear { focusAfterTransition(.firstName) }
    }

    // MARK: 2 — Your username (its own screen, like Beli)

    private var usernameStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Your username")
                .font(Theme.serif(34))
            Text("How friends find and follow you — you can change it later.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(Theme.gray)
                    TextField("username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
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
            PillButton(title: saving ? "Saving…" : "Continue") {
                Task { await saveUsername() }
            }
            .disabled(!usernameValid || availability == .taken || saving)
            .padding(.bottom, 36)
        }
        .onAppear { focusAfterTransition(.username) }
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
            Text("Add a photo so friends know it's you. You can skip it — we'll use your initials for now.")
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            Button {
                showCropPicker = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(url: avatarURL ?? session.profile?.avatarURL, size: 132,
                               name: fullName.isEmpty ? username : fullName)
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
                              display_name: fullName.isEmpty ? nil : fullName))
            // Invited by a friend (typed, or carried in from their link):
            // follow each other automatically.
            // Strip a leading "@" — the field prompts "their @username", so many
            // people type it, and the server matches the bare handle.
            let typed = inviterUsername.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
            let inviter = (typed.isEmpty ? pendingInviter : typed)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
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
            Text("Track movies somewhere else? Bring your whole list over and rank it — favorites first.")
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
            Text("Turn these on so you never miss a friend's pick or a movie hitting theaters.")
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

    /// Overlaid on a poster once it's been ranked — dims it and stamps "RANKED".
    private var rankedStamp: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.scoreGreen)
                Text("RANKED")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var firstRankStep: some View {
        VStack(spacing: 14) {
            Text("Rank your first movie or show")
                .font(Theme.serif(30))
                .minimumScaleFactor(0.8)
                .padding(.top, 26)
            Text("Pick anything you've seen — the first one is quick and easy.")
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
                Text("We couldn't load suggestions — jump in below, then use the gold + to rank anything.")
                    .font(.subheadline).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 14) {
                        ForEach(starters) { movie in
                            let ranked = store.isWatched(movie.tmdbID)
                            Button {
                                logMovie = movie
                            } label: {
                                VStack(spacing: 6) {
                                    PosterView(url: movie.posterURL, width: 100)
                                        .overlay { if ranked { rankedStamp } }
                                    Text(movie.title)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(ranked ? Theme.scoreGreen : Theme.ink)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            // Already ranked → can't re-rank from here.
                            .disabled(ranked)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                }
            }

            // Once they've ranked at least one, a clear "Done" finishes; until
            // then it's a low-key skip so the grid stays the focus.
            if store.watchedCount > 0 {
                PillButton(title: "Done — \(store.watchedCount) ranked", style: .filled) { onFinished() }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            } else {
                Button(starters.isEmpty ? "Start exploring" : "I'll explore first") { onFinished() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .padding(.bottom, 24)
            }
        }
    }
}
