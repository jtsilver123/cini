import SwiftUI

/// First-run flow for a brand-new account. Value props and phone/email/password
/// are collected before this (the static welcome + sign-up), so onboarding
/// picks up at:
///
///   0. You're in! — meet Jake, the friend everyone starts following
///   1. Create your profile — photo + name + @handle + who invited you, one screen
///   2. Find your friends — contacts + invite
///   3. Bring your history — Letterboxd ZIP / Apple Notes paste / skip
///   4. Stay in the loop — notifications opt-in (re-asked after the first rank)
///   5. Rank your first movie — a poster grid of iconic titles (required)
///   6. Meet your Recs — a swipe deck of picks based on what they ranked,
///      teaching the swipe-to-bookmark gesture (mirrors the Recs tab)
///
/// Finishing hands off to the one-time ProductTourView (wired in CiniApp).
/// Shown once (per account) when an authenticated user has zero rankings.
struct OnboardingView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    var onFinished: () -> Void

    @State private var step = 0
    /// True while a back-navigation is animating, so the step transition slides
    /// the opposite way (new step in from the left, old out to the right).
    @State private var navBack = false
    @State private var showFindFriends = false
    @State private var showSkipFriendsNudge = false
    @State private var username = ""
    @State private var inviterUsername = ""
    /// Set when the user arrived via a friend's invite link — prefilled above.
    @AppStorage("cini.pendingInviter") private var pendingInviter = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var usernameError: String?
    /// True once the user edits the @handle themselves, so we stop auto-filling
    /// it from their name on the merged profile screen.
    @State private var usernameEdited = false
    @State private var saving = false
    @State private var avatarURL: URL?
    @State private var isUploadingPhoto = false
    @State private var showCropPicker = false
    @State private var showImport = false
    @State private var importStartsWithPaste = false
    @State private var starters: [Movie] = []
    /// Movies vs TV toggle on the grid + card onboarding steps (mirrors Recs).
    @State private var onbTV = false
    @State private var logMovie: Movie?
    @State private var notifsEnabled = false
    @State private var showNotifReask = false
    /// Personalized picks for the post-rank "save what to watch" tutorial,
    /// built from the title they just ranked (similar + trending fallback).
    @State private var recCandidates: [YourListsView.RecCandidate] = []
    @State private var recBookmarkCounts: [Int: Int] = [:]
    @State private var recsLoaded = false
    /// The founder everyone auto-follows — introduced on the "You're in!" screen
    /// (Beli's "Judy"). Fetched so the avatar/name stay accurate.
    @State private var founder: Profile?
    @State private var showFounderInfo = false
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
                    insertion: .move(edge: navBack ? .leading : .trailing).combined(with: .opacity),
                    removal: .move(edge: navBack ? .trailing : .leading).combined(with: .opacity)))
        }
        .animation(.snappy, value: step)
        .nativeContentWidth()
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
        // One last, well-timed notifications ask for anyone who skipped the
        // primer — shown only after they've ranked something.
        .fullScreenCover(isPresented: $showNotifReask) {
            NotificationPrimer(
                onTurnOn: { Task { notifsEnabled = await PushManager.request(); onFinished() } },
                onSkip: { onFinished() }
            )
            .background(Theme.background.ignoresSafeArea())
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
            // Iconic, instantly-recognizable titles so the first rank is easy —
            // movies (positive ids) AND shows (negative ids, the app's TV
            // convention) so the Movies/TV toggle has a full grid either way.
            let iconicIDs = [238, 278, 155, 680, 11, 27205, 603, 13, 157336,
                             597, 329, 120, 24428, 550, 496243, 98,
                             -1396, -1399, -66732, -1668, -2316, -1398,
                             -94605, -95396, -82856, -76331, -60625, -456]
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
            founder = try? await SupabaseService.shared.profile(id: Self.founderID).asProfile
        }
    }

    /// A back chevron (so a typo'd name/username is fixable) above the
    /// progress segments for the six data steps (1–6).
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
                ForEach(1..<7, id: \.self) { index in
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
        navBack = false
        guard focus != nil else {
            withAnimation(.snappy) { step = min(step + 1, 6) }
            return
        }
        focus = nil
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.snappy) { step = min(step + 1, 6) }
        }
    }

    private func goBack() {
        focus = nil
        navBack = true
        withAnimation(.snappy) { step = max(step - 1, 0) }
    }

    /// Finish — but if they skipped the notifications primer earlier, give it one
    /// more, well-timed try now that they've actually ranked something.
    private func finishOnboarding() {
        if notifsEnabled { onFinished() } else { showNotifReask = true }
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
        case 1: profileStep        // name + @handle + photo, one screen
        case 2: findFriendsStep
        case 3: importStep
        case 4: notificationsStep
        case 5: firstRankStep
        default: recTutorialStep   // swipe picks to Want to Watch
        }
    }

    // MARK: 1 — Create your profile (name + @handle + photo, one screen)

    private var profileStep: some View {
        VStack(spacing: 0) {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                Text("Create your profile")
                    .font(Theme.serif(34))
                    .padding(.top, 4)

                // Optional photo first — initials stand in until they add one.
                Button { showCropPicker = true } label: {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(url: avatarURL ?? session.profile?.avatarURL, size: 92,
                                   name: fullName.isEmpty ? username : fullName)
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.marquee)
                            .background(Circle().fill(Theme.background))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add profile photo")
                if isUploadingPhoto {
                    ProgressView().controlSize(.small)
                } else {
                    // A nudge: photos lift engagement, so show that most people add one.
                    Text("Add a photo · 85% of members do")
                        .font(.caption).foregroundStyle(Theme.gray)
                }

                VStack(spacing: 10) {
                    // First + last sit side by side to save a row.
                    HStack(spacing: 10) {
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
                            .submitLabel(.next)
                            .focused($focus, equals: .lastName)
                            .onSubmit { focus = .username }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                    }

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
                                usernameEdited = (username != suggestedUsername)
                                checkAvailability()
                            }
                        switch availability {
                        case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.scoreGreen)
                        case .taken: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.scoreRed)
                        case .checking: ProgressView().controlSize(.small)
                        case .unknown: EmptyView()
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))

                    Text(usernameHint)
                        .font(.caption).foregroundStyle(usernameHintColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Text("@").foregroundStyle(Theme.gray)
                        TextField("Friend who invited you · optional", text: $inviterUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        // Continue is pinned in the VStack (not a safeAreaInset) so the animated
        // step transition can't clip it off the bottom — it's always tappable.
        PillButton(title: saving ? "Saving…" : "Continue") { Task { await saveUsername() } }
            .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty
                      || !usernameValid || availability == .taken || saving)
            .padding(.horizontal, 28)
            .padding(.top, 8)
        }
        .background(Theme.background)
        .sheet(isPresented: $showCropPicker) {
            CropImagePicker { image in Task { await uploadPhoto(image) } }
                .ignoresSafeArea()
        }
        .onAppear {
            if username.isEmpty, suggestedUsername.count >= 3 {
                username = suggestedUsername
                checkAvailability()
            }
            if inviterUsername.isEmpty, !pendingInviter.isEmpty { inviterUsername = pendingInviter }
            focusAfterTransition(.firstName)
        }
        // Keep the @handle in step with the name until the user edits it.
        .onChange(of: fullName) { _, _ in
            if !usernameEdited {
                username = suggestedUsername
                checkAvailability()
            }
        }
    }

    // MARK: 4 — Stay in the loop (opt-in primer; re-asked after the first rank)

    private var notificationsStep: some View {
        NotificationPrimer(
            onTurnOn: { Task { notifsEnabled = await PushManager.request(); advance() } },
            onSkip: { advance() }
        )
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
                .padding(.bottom, 30)
        }
        .alert("Who's \(founderFirstName)?", isPresented: $showFounderInfo) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Hey, I'm \(founderFirstName) — I built Cini because I'm obsessed with ranking everything I watch. You start out following me so your feed has great picks from day one; unfollow any time.")
        }
    }

    // MARK: 2 — Find your friends (Beli puts this in onboarding)

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

    /// A handle guess from the entered name: "janedoe", trimmed to 20 chars.
    private var suggestedUsername: String {
        let base = (firstName + lastName)
            .lowercased()
            .filter { $0.isLowercase || $0.isNumber }
        return String(base.prefix(20))
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

    // MARK: 3 — Bring your history

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

    // MARK: 5 — Rank your first movie

    /// A Recs-style teaching block for the onboarding grid/card steps: the same
    /// view-toggle control the Recs page uses, shown LOCKED to this step's mode,
    /// plus a line on what it's best for and that it's switchable on Recs.
    private func recsViewTeacher(isGrid: Bool) -> some View {
        VStack(spacing: 10) {
            // The locked view toggle — the SAME purpose-labeled control the Recs
            // page uses, current one selected, a lock so they just learn it here.
            HStack(spacing: 0) {
                ForEach([false, true], id: \.self) { grid in
                    let on = (grid == isGrid)
                    HStack(spacing: 5) {
                        Image(systemName: grid ? "square.grid.2x2" : "rectangle.stack")
                            .font(.caption.weight(.bold))
                        Text(grid ? "Rank watched" : "Find to watch")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(on ? Theme.background : Theme.gray)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(on ? Theme.marquee : .clear))
                }
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.gray)
                    .padding(.horizontal, 6)
            }
            .padding(4)
            .background(Capsule().fill(Theme.fill))

            Text(isGrid
                 ? "“Rank watched” is best for ranking things you've already seen. Find both views on your Recs page."
                 : "“Find to watch” is best for discovering new things. Find both views on your Recs page.")
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
        }
    }

    /// Starters / rec candidates filtered to the Movies/TV toggle.
    private var visibleStarters: [Movie] {
        starters.filter { onbTV ? $0.mediaKind == "tv" : $0.mediaKind != "tv" }
    }
    private var visibleRecCandidates: [YourListsView.RecCandidate] {
        recCandidates.filter { onbTV ? $0.movie.mediaKind == "tv" : $0.movie.mediaKind != "tv" }
    }

    private var firstRankStep: some View {
        VStack(spacing: 14) {
            Text("Rank your first movie/show")
                .font(Theme.serif(30))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 26)
            recsViewTeacher(isGrid: true)

            SegmentedPillControl(
                segments: ["Movies", "TV Shows"],
                selection: Binding(get: { onbTV ? 1 : 0 }, set: { onbTV = $0 == 1 }))
                .padding(.horizontal, 24)

            if starters.isEmpty {
                // Posters come from TMDB; if that didn't load (e.g. no network
                // on first launch) don't show a blank grid — point them at search.
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40)).foregroundStyle(Theme.gray)
                Text("We couldn't load suggestions. Search for anything you've watched and tap + to rank it.")
                    .font(.subheadline).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
                Spacer()
            } else if visibleStarters.isEmpty {
                // Toggled to a kind with nothing left — nudge to the other tab.
                Spacer()
                Text("No \(onbTV ? "shows" : "movies") here — try the \(onbTV ? "Movies" : "TV Shows") tab above.")
                    .font(.subheadline).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    // Shared grid (CIN-33): tap to rank, ✕ to dismiss, hold to
                    // save to Want to Watch.
                    SuggestionGrid(
                        movies: visibleStarters,
                        onRank: { logMovie = $0 },
                        onSave: { movie in
                            guard !store.isOnWatchlist(movie.tmdbID) else { return }
                            Task { await store.toggleWatchlist(movie: movie) }
                            ToastCenter.shared.show("Bookmarked to Want to Watch ✓")
                        },
                        onDismiss: { movie in
                            withAnimation(.snappy) { starters.removeAll { $0.tmdbID == movie.tmdbID } }
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                }
            }

            // Ranking the first title is encouraged but no longer required —
            // once they've ranked one, "Continue" leads into the rec tutorial;
            // otherwise a gentle nudge plus a skip so no one ever gets stuck.
            if store.watchedCount > 0 {
                PillButton(title: "Continue · \(store.watchedCount) ranked", style: .filled) { advance() }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            } else if starters.isEmpty {
                // No posters loaded (offline) — let them through to explore.
                Button("Start exploring") { finishOnboarding() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .padding(.bottom, 24)
            } else {
                VStack(spacing: 12) {
                    Label("Tap a poster to rank your first", systemImage: "hand.tap")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.gray)
                    Button("Skip for now") { advance() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: 6 — Meet your Recs (swipe deck of personalized picks)

    private var recTutorialStep: some View {
        VStack(spacing: 14) {
            Text("Meet your Recs")
                .font(Theme.serif(30))
                .minimumScaleFactor(0.8)
                .padding(.top, 24)
            recsViewTeacher(isGrid: false)

            SegmentedPillControl(
                segments: ["Movies", "TV Shows"],
                selection: Binding(get: { onbTV ? 1 : 0 }, set: { onbTV = $0 == 1 }))
                .padding(.horizontal, 24)

            Spacer(minLength: 8)

            if !recsLoaded {
                ProgressView()
            } else if visibleRecCandidates.isEmpty {
                // Rare (offline / no posters / none of this kind) — don't trap
                // them on an empty deck.
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title).foregroundStyle(Theme.gray)
                    Text("More picks once you've ranked a few")
                        .font(.subheadline.weight(.semibold))
                    Text("As you rank, Cini learns your taste and starts suggesting what to watch.")
                        .font(.caption).foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center).padding(.horizontal, 36)
                }
            } else {
                // The shared swipe deck — its built-in practice cards teach the
                // gesture first, then real picks follow.
                RecCardDeck(
                    candidates: visibleRecCandidates,
                    onOpen: { _ in },
                    onLog: { logMovie = $0 },
                    onSave: { movie in Task { await store.toggleWatchlist(movie: movie) } },
                    onUnsave: { movie in Task { await store.toggleWatchlist(movie: movie) } },
                    onRefresh: { Task { await loadOnboardingRecs(force: true) } },
                    showRank: true,
                    onRank: { logMovie = $0 },
                    richDetail: true,
                    bookmarkCounts: recBookmarkCounts
                )
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 8)

            PillButton(title: "Done", style: .filled) { finishOnboarding() }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .task { await loadOnboardingRecs() }
    }

    /// Build the post-rank picks from the title they just ranked: titles
    /// similar to their current #1, topped up with this week's trending.
    private func loadOnboardingRecs(force: Bool = false) async {
        if force { recCandidates = []; recsLoaded = false }
        guard recCandidates.isEmpty else { return }

        let topID = store.watchedItems.first?.id
        var pending: [(id: Int, reason: String)] = []
        var seen = Set<Int>()

        if let topID, let similar = try? await TMDBService.shared.similar(to: topID) {
            let topTitle = store.movie(topID)?.title ?? "your favorite"
            for movie in similar.prefix(12)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Because you liked \(topTitle)"))
            }
        }
        if pending.count < 8, let trending = try? await TMDBService.shared.trending() {
            for movie in trending.prefix(12)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Trending this week"))
            }
        }

        // Enrich posters/overview before showing the cards.
        await withTaskGroup(of: Void.self) { group in
            for id in pending.prefix(10).map(\.id) {
                group.addTask { await store.enrich(id) }
            }
        }

        recCandidates = pending.compactMap { candidate in
            store.movie(candidate.id).map {
                YourListsView.RecCandidate(movie: $0, reason: candidate.reason)
            }
        }
        recBookmarkCounts = await SupabaseService.shared.watchlistCounts(movieIDs: pending.map(\.id))
        recsLoaded = true
    }
}

/// A friendly notifications opt-in (CIN onboarding): one clear "turn on" CTA
/// with a sample of the kind of alert you'd get, so the ask feels concrete.
private struct NotificationPrimer: View {
    var onTurnOn: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Stay in the loop")
                .font(Theme.serif(34))
                .foregroundStyle(Theme.ink)
            Text("Get a heads-up when a friend ranks something, sends you a rec, or replies to you.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            // A sample of what an alert looks like, with a faint card peeking
            // behind it for that stacked-notifications feel.
            ZStack {
                sampleBanner
                    .scaleEffect(0.93)
                    .offset(y: 16)
                    .opacity(0.45)
                sampleBanner
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)

            Spacer()
            PillButton(title: "Turn on notifications") { onTurnOn() }
                .padding(.horizontal, 24)
            Button("Maybe later") { onSkip() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 30)
        }
    }

    private var sampleBanner: some View {
        HStack(spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("Cini").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text("@maya ranked Dune: Part Two 🎬")
                    .font(.subheadline).foregroundStyle(Theme.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("now").font(.caption2).foregroundStyle(Theme.gray)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 10, y: 4)
    }

    private var appIcon: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Theme.marquee)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "film.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.background)
            )
    }
}
