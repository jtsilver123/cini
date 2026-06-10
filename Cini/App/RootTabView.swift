import SwiftUI

/// 5-tab bar identical to Beli's IA:
/// Feed · Your Lists · Search (raised teal +) · Leaderboard · Profile
///
/// On iOS 26+/27 this uses the native Tab API with a search-role tab so the
/// bar renders as floating Liquid Glass, minimizes on scroll, and splits the
/// search tab into its own lens — the platform-native take on Beli's raised
/// center button. Earlier OSes get the classic raised teal +.
struct RootTabView: View {
    @State private var selectedTab: Tab = .feed

    enum Tab: Hashable {
        case feed, lists, search, leaderboard, profile
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            modernTabs
        } else {
            legacyTabs
        }
    }

    @available(iOS 26.0, *)
    private var modernTabs: some View {
        TabView(selection: $selectedTab) {
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
        TabView(selection: $selectedTab) {
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
            RaisedSearchButton { selectedTab = .search }
                .allowsHitTesting(selectedTab != .search)
                .opacity(selectedTab == .search ? 0 : 1)
        }
    }
}

private struct RaisedSearchButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.teal))
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
