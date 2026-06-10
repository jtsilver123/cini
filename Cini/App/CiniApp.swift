import SwiftUI

@main
struct CiniApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isAuthenticated {
                    RootTabView()
                } else {
                    AuthView()
                }
            }
            .environment(session)
            .environment(session.rankingStore)
            .tint(Theme.teal)
            .task { await session.bootstrap() }
        }
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
                if session != nil { await loadProfile() }
            case .signedOut:
                isAuthenticated = false
                profile = nil
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
        try? await supabase.signOut()
    }
}
