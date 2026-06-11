import SwiftUI

@main
struct CiniApp: App {
    @UIApplicationDelegateAdaptor(PushManager.self) private var pushManager
    @State private var session = AppSession()
    @AppStorage("cini.hasOnboarded") private var hasOnboarded = false
    /// "dark" · "light" · "system" (default — follows the device).
    @AppStorage("cini.appearance") private var appearance = "system"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "system": nil       // follow the device setting
        default: .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isAuthenticated {
                    RootTabView()
                        .fullScreenCover(isPresented: needsOnboarding) {
                            OnboardingView {
                                hasOnboarded = true
                            }
                        }
                } else {
                    AuthView()
                }
            }
            .environment(session)
            .environment(session.rankingStore)
            .tint(Theme.marquee)
            .preferredColorScheme(colorScheme)
            .task { await session.bootstrap() }
        }
    }

    /// First run: authenticated, never onboarded on this device, and the
    /// account has no rankings yet (an existing user on a new phone skips).
    private var needsOnboarding: Binding<Bool> {
        Binding(
            get: {
                !hasOnboarded
                    && session.rankingStore.isLoaded
                    && session.rankingStore.watchedCount == 0
            },
            set: { if !$0 { hasOnboarded = true } }
        )
    }
}

/// Session-level state: auth, current profile, and the ranking store.
@Observable
@MainActor
final class AppSession {
    var isAuthenticated = false
    var profile: Profile?
    var globalRank: Int?

    let rankingStore = RankingStore()
    private let supabase = SupabaseService.shared

    func bootstrap() async {
        // Restore an existing Supabase session and observe changes.
        for await (event, session) in supabase.client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn:
                isAuthenticated = session != nil
                if session != nil {
                    await loadProfile()
                    PushManager.enable()
                    // Warm the social cache so the log flow's friend chips
                    // and Recommend sheet open instantly.
                    FriendsCache.shared.warm()
                }
            case .signedOut:
                isAuthenticated = false
                profile = nil
                FeedDiskCache.clear()
            default:
                break
            }
        }
    }

    func loadProfile() async {
        guard let id = supabase.currentUserID else { return }
        async let profileRow = supabase.profile(id: id)
        async let rank = supabase.globalRank(userID: id)
        await rankingStore.load()
        profile = try? await profileRow.asProfile
        globalRank = try? await rank
    }

    func signOut() async {
        // This device must stop receiving the old account's pushes.
        if let token = PushManager.currentToken {
            await supabase.unregisterDeviceToken(token)
        }
        try? await supabase.signOut()
    }
}
