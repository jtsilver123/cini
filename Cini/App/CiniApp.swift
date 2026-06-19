import SwiftUI

@main
struct CiniApp: App {
    @UIApplicationDelegateAdaptor(PushManager.self) private var pushManager
    @State private var session = AppSession()
    /// User ids that have finished onboarding on this device (comma-joined).
    /// Per-account so a new signup on a shared phone still onboards.
    @AppStorage("cini.onboardedUserIDs") private var onboardedUserIDsRaw = ""
    /// Accounts that have seen the post-onboarding product tour.
    @AppStorage("cini.touredUserIDs") private var touredUserIDsRaw = ""
    @State private var showOnboarding = false
    @State private var showTour = false
    /// A list opened from a shared `cini://list?id=` link.
    @State private var sharedList: CustomList?
    /// A list link tapped while signed out — opened once the user is in the app.
    @State private var pendingListID: UUID?

    private func isOnboarded(_ uid: String) -> Bool {
        onboardedUserIDsRaw.split(separator: ",").map(String.init).contains(uid)
    }
    private func markOnboarded(_ uid: String) {
        guard !isOnboarded(uid) else { return }
        onboardedUserIDsRaw += onboardedUserIDsRaw.isEmpty ? uid : ",\(uid)"
    }
    private func isToured(_ uid: String) -> Bool {
        touredUserIDsRaw.split(separator: ",").map(String.init).contains(uid)
    }
    private func markToured(_ uid: String) {
        guard !isToured(uid) else { return }
        touredUserIDsRaw += touredUserIDsRaw.isEmpty ? uid : ",\(uid)"
    }

    /// Changes whenever the signed-in account or its load state changes, so the
    /// onboarding check re-runs for a brand-new account (not just on first load).
    private var onboardingKey: String {
        "\(SupabaseService.shared.currentUserID?.uuidString ?? "none")-\(session.rankingStore.isLoaded)"
    }

    /// Decide whether THIS account needs onboarding, once its rankings resolve.
    /// New account (0 watched) → onboard. Returning user on a fresh device
    /// (already has rankings) → mark done and go straight to the app.
    private func evaluateOnboarding() async {
        guard let uid = SupabaseService.shared.currentUserID?.uuidString,
              session.rankingStore.isLoaded else { return }
        if !isOnboarded(uid) {
            if session.rankingStore.watchedCount == 0 {
                withAnimation { showOnboarding = true }
                return                       // tour runs after onboarding finishes
            }
            markOnboarded(uid)               // returning user on a fresh device
        }
        // Onboarded (now or already) — run the one-time tour if this account
        // hasn't seen it yet. Per account, exactly once.
        if !isToured(uid) && !showOnboarding {
            withAnimation { showTour = true }
        }
        consumePendingList()   // returning user with a stashed list link
    }
    /// "dark" (default — the cinema-dark room) · "light" · "system" (follows
    /// the device). Dark is the intended look on both iPhone and iPad.
    @AppStorage("cini.appearance") private var appearance = "dark"
    /// Carried in from a friend's invite link (`cini://invite?u=…`) so
    /// onboarding prefills it / we auto-follow — no typing a username.
    @AppStorage("cini.pendingInviter") private var pendingInviter = ""

    init() {
        // Beli-style tab bar: a solid, opaque bar with a top hairline — NOT
        // iOS 26's floating Liquid Glass. Configuring an opaque appearance
        // opts the classic tab bar out of the glass treatment.
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(Theme.surface)
        bar.shadowColor = UIColor(Theme.hairline)
        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(Theme.gray)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(Theme.gray)]
        item.selected.iconColor = UIColor(Theme.marquee)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.marquee)]
        bar.stackedLayoutAppearance = item
        bar.inlineLayoutAppearance = item
        bar.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "system": nil       // follow the device setting
        default: .dark
        }
    }

    /// Route a deep link into the app. Two shapes arrive here:
    ///   • a `cini://…` custom scheme, used by the trycini.com pages' in-page
    ///     "Open Cini" buttons (same-domain taps can't fire a Universal Link); and
    ///   • a Universal Link `https://trycini.com/i|/l…`, which iOS hands straight
    ///     to the installed app — no Safari, no "address is invalid" detour —
    ///     when an invite/list link is tapped from Messages, Mail, etc.
    private func handleURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let isList: Bool
        let isInvite: Bool
        if url.scheme == "cini" {
            isList = url.host == "list"
            isInvite = !isList   // cini://invite (or bare cini://) → invite
        } else if url.scheme == "https",
                  url.host == "trycini.com" || url.host == "www.trycini.com" {
            isList = url.path.hasPrefix("/l")
            isInvite = url.path.hasPrefix("/i")
        } else {
            return
        }

        if isList {
            // /l?id=<uuid> → open that list (if it's viewable). Signed out,
            // stash it and open once they're in the app.
            guard let idStr = comps.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: idStr) else { return }
            if session.isAuthenticated { openList(id) } else { pendingListID = id }
            return
        }
        if isInvite { handleInvite(comps) }
    }

    /// Fetch + present a shared list, or explain why it can't open.
    private func openList(_ id: UUID) {
        Task {
            if let list = await SupabaseService.shared.list(id: id) { sharedList = list }
            else { ToastCenter.shared.show("That list is private or unavailable.") }
        }
    }

    /// Open a stashed list link — only once the user is fully in the app (never
    /// over onboarding or the tour).
    private func consumePendingList() {
        guard session.isAuthenticated, !showOnboarding, !showTour,
              let id = pendingListID else { return }
        pendingListID = nil
        openList(id)
    }

    /// `cini://invite?u=<username>` from a friend's invite link: remember the
    /// inviter so onboarding prefills it, and if we're already signed in,
    /// follow them right away — the invitee never types a username.
    private func handleInvite(_ comps: URLComponents) {
        guard let raw = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return }
        let username = raw.replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { return }
        // Your own link is a no-op — don't leave a stale inviter pointing at you.
        if username.lowercased() == session.profile?.username.lowercased() {
            pendingInviter = ""
            return
        }
        pendingInviter = username
        if session.isAuthenticated {
            Task {
                if await SupabaseService.shared.redeemInvite(from: username) {
                    pendingInviter = ""
                    await session.loadProfile()
                    ToastCenter.shared.show("You're now following @\(username) 🎬")
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !session.didResolveAuth {
                    LaunchView()
                } else if session.isAuthenticated {
                    // Onboarding is a TOP-LEVEL branch, not a fullScreenCover.
                    // A cover requested during the Auth→Root swap is silently
                    // dropped (which left new accounts stuck past onboarding);
                    // a branch can't be. Tracked per user id, so a second
                    // account on a shared phone still onboards, while a
                    // returning user (who already has rankings) skips it.
                    Group {
                        if showOnboarding {
                            OnboardingView {
                                if let uid = SupabaseService.shared.currentUserID?.uuidString {
                                    markOnboarded(uid)
                                    // New user just finished onboarding → quick tour.
                                    if !isToured(uid) { showTour = true }
                                }
                                withAnimation { showOnboarding = false }
                                consumePendingList()   // if no tour follows
                            }
                        } else {
                            RootTabView()
                                // Overlay (not a cover) so it can't be dropped
                                // during the onboarding→app transition.
                                .overlay {
                                    if showTour {
                                        ProductTourView {
                                            if let uid = SupabaseService.shared.currentUserID?.uuidString {
                                                markToured(uid)
                                            }
                                            withAnimation { showTour = false }
                                            consumePendingList()   // open a stashed list link
                                        }
                                        .transition(.opacity)
                                    }
                                }
                        }
                    }
                    // Keyed on the user id so it re-evaluates for a new account
                    // even if the ranking store was already loaded.
                    .task(id: onboardingKey) { await evaluateOnboarding() }
                } else {
                    WelcomeView()
                }
            }
            .environment(session)
            .environment(session.rankingStore)
            .tint(Theme.marquee)
            .preferredColorScheme(colorScheme)
            .animation(.easeInOut(duration: 0.25), value: session.didResolveAuth)
            .task { await session.bootstrap() }
            .onOpenURL { handleURL($0) }
            // Universal Links (https://trycini.com/i|/l) arrive as a browsing
            // user activity; route them through the same handler.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { handleURL(url) }
            }
            // A shared list link (cini://list?id=) opens the list right here.
            .sheet(item: $sharedList) { list in
                NavigationStack {
                    CustomListScreen(list: list,
                                     isSelf: list.userId == SupabaseService.shared.currentUserID)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { sharedList = nil }
                            }
                        }
                }
                // Same shared router the tab bar uses, so a tapped movie/profile
                // inside the list navigates correctly.
                .environment(TabRouter.shared)
            }
        }
    }

}

/// Session-level state: auth, current profile, and the ranking store.
@Observable
@MainActor
final class AppSession {
    var isAuthenticated = false
    /// False until the first auth event resolves. Lets the UI show a branded
    /// launch screen while the saved session restores, instead of flashing the
    /// auth screen for a beat on every relaunch.
    var didResolveAuth = false
    var profile: Profile?
    var globalRank: Int?
    /// Friends brought to Cini (= unlock credits) and the features unlocked
    /// with them. Drive the referral-unlock wall (aggregate scores, etc.).
    var referralCount = 0
    var unlockedFeatures: Set<String> = []

    /// Referral credits not yet spent on an unlock.
    var availableUnlocks: Int { max(0, referralCount - unlockedFeatures.count) }
    func isUnlocked(_ feature: String) -> Bool { unlockedFeatures.contains(feature) }

    let rankingStore = RankingStore()
    private let supabase = SupabaseService.shared

    func bootstrap() async {
        // Restore an existing Supabase session and observe changes.
        for await (event, session) in supabase.client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn:
                isAuthenticated = session != nil
                didResolveAuth = true
                if session != nil {
                    await loadProfile()
                    // Don't prompt at sign-in — onboarding primes and asks.
                    // Returning users who already allowed just refresh their token.
                    PushManager.registerIfAuthorized()
                    // Warm the social cache so the log flow's friend chips
                    // and Recommend sheet open instantly.
                    FriendsCache.shared.warm()
                }
            case .signedOut:
                isAuthenticated = false
                didResolveAuth = true
                profile = nil
                // Clear in-memory rankings too (not just disk) so a new signup
                // on this device starts clean and re-runs onboarding — without
                // this, the next account inherited the prior one's watched count
                // and skipped onboarding.
                rankingStore.reset()
                FeedDiskCache.clear()
                RankingDiskCache.clear()
                ImportQueue.shared.clear()
            default:
                break
            }
        }
    }

    func loadProfile() async {
        guard let id = supabase.currentUserID else { return }
        async let profileRow = supabase.profile(id: id)
        async let rank = supabase.globalRank(userID: id)
        async let referrals = supabase.referralCount()
        async let unlocked = supabase.unlockedFeatures()
        await rankingStore.load()
        // Keep the server's idea of our timezone current for the evening
        // Tonight's Pick push (sent at ~7pm local).
        Task { await supabase.setTimezone(TimeZone.current.identifier) }
        profile = try? await profileRow.asProfile
        globalRank = try? await rank
        referralCount = await referrals
        unlockedFeatures = Set(await unlocked)
    }

    func signOut() async {
        // This device must stop receiving the old account's pushes.
        if let token = PushManager.currentToken {
            await supabase.unregisterDeviceToken(token)
        }
        try? await supabase.signOut()
    }
}

/// Branded launch screen shown while the saved session restores — the marquee
/// wordmark on the house-lights-down background, like Beli's splash, so a
/// returning user never sees the auth screen flash by.
struct LaunchView: View {
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                MarqueeBulbStrip(count: 11, bulb: 6)
                Text("cini")
                    .font(Theme.display(64))
                    .foregroundStyle(Theme.marquee)
                    .shadow(color: Theme.marquee.opacity(glow ? 0.55 : 0.2), radius: glow ? 22 : 10)
                Text("EVERY FILM · RANKED")
                    .font(.caption2.weight(.bold))
                    .tracking(4)
                    .foregroundStyle(Theme.gray)
                MarqueeBulbStrip(count: 11, bulb: 6)
            }
        }
        .filmGrain(0.05)
        .onAppear {
            guard !reduceMotion else { return }   // hold a steady glow
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}
