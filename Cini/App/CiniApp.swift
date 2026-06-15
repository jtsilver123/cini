import SwiftUI

@main
struct CiniApp: App {
    @UIApplicationDelegateAdaptor(PushManager.self) private var pushManager
    @State private var session = AppSession()
    @AppStorage("cini.hasOnboarded") private var hasOnboarded = false
    @State private var showOnboarding = false
    /// "dark" · "light" · "system" (default — follows the device).
    @AppStorage("cini.appearance") private var appearance = "system"
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

    /// `cini://invite?u=<username>` from a friend's invite link: remember the
    /// inviter so onboarding prefills it, and if we're already signed in,
    /// follow them right away — the invitee never types a username.
    private func handleInvite(_ url: URL) {
        guard url.scheme == "cini",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return }
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
                    RootTabView()
                        .fullScreenCover(isPresented: $showOnboarding) {
                            OnboardingView {
                                hasOnboarded = true
                                showOnboarding = false
                            }
                        }
                        // First run: authenticated, never onboarded on this
                        // device, and the account has no rankings (an
                        // existing user on a new phone skips). Presented
                        // AFTER the Auth→Root transition settles: a cover
                        // requested mid-swap is silently dropped and leaves
                        // a dead, untouchable layer (seen with fast email
                        // sign-ins, where the store loads during the swap).
                        .task(id: session.rankingStore.isLoaded) {
                            guard !hasOnboarded,
                                  session.rankingStore.isLoaded,
                                  session.rankingStore.watchedCount == 0 else { return }
                            try? await Task.sleep(for: .milliseconds(600))
                            guard !hasOnboarded, session.isAuthenticated else { return }
                            showOnboarding = true
                        }
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
            .onOpenURL { handleInvite($0) }
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

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("cini")
                    .font(Theme.display(64))
                    .foregroundStyle(Theme.marquee)
                    .shadow(color: Theme.marquee.opacity(glow ? 0.55 : 0.2), radius: glow ? 22 : 10)
                Text("EVERY FILM · RANKED")
                    .font(.caption2.weight(.bold))
                    .tracking(4)
                    .foregroundStyle(Theme.gray)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}
