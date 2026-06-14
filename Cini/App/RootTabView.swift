import SwiftUI

/// 5-tab bar identical to Beli's IA:
/// Feed · Your Lists · Search (raised teal +) · Leaderboard · Profile
///
/// Solid Beli-style bar on every OS — an opaque background with a top
/// hairline and a raised center `+`, NOT iOS 26's floating Liquid Glass
/// (`CiniApp` configures `UITabBarAppearance` to stay opaque).
/// Lets any screen jump tabs (the feed's search bar opens the Search tab,
/// so every entry point lands on ONE search interface).
@Observable
@MainActor
final class TabRouter {
    /// One router for the whole app — PushManager routes notification taps
    /// through it from outside the SwiftUI environment.
    static let shared = TabRouter()

    var selection: RootTabView.Tab = .feed {
        didSet {
            if oldValue != selection && oldValue != .search { lastNonSearch = oldValue }
            if oldValue != selection { visibleMovie = nil }
        }
    }
    /// The page under search — where its X returns to.
    private(set) var lastNonSearch: RootTabView.Tab = .feed

    /// Set before jumping to search to land on the Members tab.
    var openMembersSearch = false
    /// The movie page currently on screen — Ask Cini opens with it
    /// pinned, so "is this good?" needs zero typing. Cleared on tab
    /// switches so a page left behind in another tab's stack can't
    /// haunt the chat.
    var visibleMovie: Movie?

    /// Set before jumping to lists to land on a specific subtab.
    var pendingListsTab: YourListsView.SubTab?

    /// Set before jumping to lists to open a specific custom list
    /// (agent receipt chips use this).
    var pendingCustomListID: UUID?

    /// Set before jumping to search to land on a browse mode ("trending").
    var pendingSearchBrowse: SearchView.BrowseKind?

    /// "Reorder within my list" from a movie page: open Watched in
    /// reorder mode.
    var pendingReorder = false

    /// Tapped push notification → the relevant content (consumed by FeedView).
    var pendingPushMovieID: Int?
    var pendingPushMember: MemberRef?

    /// Route a tapped push by its payload: movie pushes (likes, comments,
    /// recs, watchlist alerts) open the movie page; follower pushes open
    /// the actor's profile; anything else lands on the feed.
    func routePush(userInfo: [AnyHashable: Any]) {
        selection = .feed
        // Rec requests land on the feed, where the "wants a rec" banner
        // offers the respond flow — the actor's profile would be a detour.
        if userInfo["kind"] as? String == "rec_request" { return }
        let movieID = (userInfo["movie_id"] as? Int)
            ?? (userInfo["movie_id"] as? NSNumber)?.intValue
            ?? (userInfo["movie_id"] as? String).flatMap(Int.init)
        if let movieID {
            pendingPushMovieID = movieID
        } else if let actorID = (userInfo["actor_id"] as? String).flatMap(UUID.init),
                  let username = userInfo["actor_username"] as? String {
            pendingPushMember = MemberRef(id: actorID, username: username)
        }
    }

    func closeSearch() { selection = lastNonSearch }

    /// Bumped when the user taps the tab they're already on — each tab's
    /// root scroll view watches its counter and jumps back to the top.
    private(set) var retap: [RootTabView.Tab: Int] = [:]
    func tappedActiveTab(_ tab: RootTabView.Tab) { retap[tab, default: 0] += 1 }
}

struct RootTabView: View {
    @State private var router = TabRouter.shared
    @State private var network = NetworkMonitor.shared
    @State private var showChat = false

    enum Tab: Hashable {
        case feed, lists, search, leaderboard, profile
    }

    var body: some View {
        beliTabs
        .environment(router)
        // Ask Cini floats bottom-right on every page — but only where the
        // on-device model can exist (iOS 26+/27 on Apple Intelligence
        // hardware). Older OSes and never-eligible devices shouldn't see
        // a prominent button that leads to an unavailable screen.
        .overlay(alignment: .bottomTrailing) {
            if #available(iOS 26.0, *), ChatEligibility.canEverBeAvailable {
                Button {
                    showChat = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(Theme.marquee))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask Cini")
                .padding(.trailing, 16)
                .padding(.bottom, 64)
                .ignoresSafeArea(.keyboard)
            }
        }
        // Offline banner, app-wide — the one always-visible "you're not
        // connected" signal, above the tabs so nothing hides it.
        .overlay(alignment: .top) {
            if !network.isOnline {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                    Text("No internet connection")
                        .font(.subheadline.weight(.semibold))
                }
                // background-on-ink keeps contrast in BOTH modes (white
                // text vanished on dark mode's cream ink).
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.ink)
                .transition(.move(edge: .top).combined(with: .opacity))
                .ignoresSafeArea(edges: .top)
                .accessibilityLabel("No internet connection")
            }
        }
        .animation(.snappy, value: network.isOnline)
        // Write failures and confirmations surface here, app-wide.
        .overlay { ToastOverlay() }
        .sheet(isPresented: $showChat) {
            NavigationStack {
                CiniChatView()
            }
            // The sheet is attached OUTSIDE the .environment(router)
            // injection above, so it inherits nothing from it — without
            // this line, the chat's @Environment(TabRouter.self) traps
            // the instant the sheet opens (the .44 tap-to-crash).
            .environment(router)
            .presentationDragIndicator(.visible)
        }
    }

    /// Beli's bar: a solid, opaque bottom bar with a top hairline, labeled
    /// icons, and a raised teal `+` in the center for Search. Opaque on every
    /// OS — `CiniApp` configures `UITabBarAppearance` so iOS 26 doesn't turn
    /// it into floating Liquid Glass.
    private var beliTabs: some View {
        // Custom binding so tapping the already-active tab is detected
        // (scroll-to-top) — the plain $selection binding can't see a re-tap.
        let selection = Binding<Tab>(
            get: { router.selection },
            set: { newValue in
                if newValue == router.selection { router.tappedActiveTab(newValue) }
                router.selection = newValue
            }
        )
        return TabView(selection: selection) {
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
