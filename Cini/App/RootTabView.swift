import SwiftUI

/// 5-tab bar identical to Beli's IA:
/// Feed · Your Lists · Search (raised teal +) · Leaderboard · Profile
///
/// On iOS 26+/27 this uses the native Tab API with a search-role tab so the
/// bar renders as floating Liquid Glass, minimizes on scroll, and splits the
/// search tab into its own lens — the platform-native take on Beli's raised
/// center button. Earlier OSes get the classic raised teal +.
/// Lets any screen jump tabs (the feed's search bar opens the Search tab,
/// so every entry point lands on ONE search interface).
@Observable
@MainActor
final class TabRouter {
    var selection: RootTabView.Tab = .feed
}

struct RootTabView: View {
    @State private var router = TabRouter()

    enum Tab: Hashable {
        case feed, lists, search, leaderboard, profile
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                modernTabs
            } else {
                legacyTabs
            }
        }
        .environment(router)
    }

    @available(iOS 26.0, *)
    private var modernTabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selection) {
            SwiftUI.Tab("Feed", systemImage: "newspaper", value: Tab.feed) {
                FeedView()
            }
            SwiftUI.Tab("Your Lists", systemImage: "list.bullet", value: Tab.lists) {
                YourListsView()
            }
            SwiftUI.Tab("Leaderboard", systemImage: "trophy", value: Tab.leaderboard) {
                LeaderboardView()
            }
            SwiftUI.Tab("Profile", systemImage: "person.crop.circle", value: Tab.profile) {
                ProfileView()
            }
            SwiftUI.Tab(value: Tab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    private var legacyTabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selection) {
            FeedView()
                .tabItem { Label("Feed", systemImage: "newspaper") }
                .tag(Tab.feed)

            YourListsView()
                .tabItem { Label("Your Lists", systemImage: "list.bullet") }
                .tag(Tab.lists)

            SearchView()
                .tabItem { Label("Search", systemImage: "plus.circle.fill") }
                .tag(Tab.search)

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "trophy") }
                .tag(Tab.leaderboard)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        .overlay(alignment: .bottom) {
            RaisedSearchButton { router.selection = .search }
                .allowsHitTesting(router.selection != .search)
                .opacity(router.selection == .search ? 0 : 1)
        }
    }
}

private struct RaisedSearchButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.background)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.marquee))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .offset(y: -14)
        .accessibilityLabel("Search and log a movie")
    }
}

#Preview {
    RootTabView()
        .environment(AppSession())
        .environment(RankingStore())
}
