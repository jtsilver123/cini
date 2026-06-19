import SwiftUI
import UIKit

/// 5-tab bar identical to Beli's IA:
/// Feed · Your Lists · Search (filled center `+`) · Leaderboard · Profile
///
/// Solid Beli-style bar on every OS — an opaque background with a top
/// hairline and a filled marquee `+` disc inline at center, NOT iOS 26's
/// floating Liquid Glass (`CiniApp` configures `UITabBarAppearance` to stay
/// opaque). The Profile tab shows the signed-in user's own avatar.
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
    /// A tapped watch-match / invite → open the Plan-a-Watch sheet.
    var pendingWatchPlan: WatchPlanContext?

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
        let kind = userInfo["kind"] as? String
        let actor: MemberRef? = {
            guard let actorID = (userInfo["actor_id"] as? String).flatMap(UUID.init),
                  let username = (userInfo["actor_username"] as? String)?
                      .trimmingCharacters(in: .whitespaces), !username.isEmpty else { return nil }
            return MemberRef(id: actorID, username: username)
        }()
        // A watch-match / invite opens the Plan-a-Watch sheet for that title +
        // friend, not the plain movie page.
        if kind == "watch_match" || kind == "watch_invite", let movieID, let actor {
            pendingWatchPlan = WatchPlanContext(movieID: movieID, friend: actor)
            return
        }
        if let movieID {
            pendingPushMovieID = movieID
        } else if let actor {
            pendingPushMember = actor
        }
    }

    func closeSearch() { selection = lastNonSearch }

    /// Bumped when the user taps the tab they're already on — each tab's
    /// root scroll view watches its counter and jumps back to the top.
    private(set) var retap: [RootTabView.Tab: Int] = [:]
    func tappedActiveTab(_ tab: RootTabView.Tab) { retap[tab, default: 0] += 1 }
}

struct RootTabView: View {
    @Environment(AppSession.self) private var session
    @State private var router = TabRouter.shared
    @State private var network = NetworkMonitor.shared
    @State private var showChat = false
    /// The signed-in user's avatar, rendered circular for the Profile tab —
    /// like Beli, your own photo IS the Profile tab icon. Reloads whenever
    /// the avatar URL changes (URLs are cache-busted on a photo change).
    @State private var profileTabIcon: UIImage?

    enum Tab: Hashable {
        case feed, swipe, search, lists, profile
    }

    /// The center Search action, Beli-style: a solid marquee disc with a clean
    /// WHITE plus, sitting inline in the bar (not a floating FAB) and always in
    /// the accent color regardless of selection. Drawn by hand rather than
    /// `plus.circle.fill` (whose plus is a see-through cutout that reads thin
    /// and dark on the opaque bar).
    private static let searchTabIcon: UIImage = {
        let d: CGFloat = 29
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: d, height: d))
        return renderer.image { _ in
            UIColor(Theme.marquee).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d)).fill()
            UIColor.white.setFill()
            let c = d / 2, arm = d * 0.28, thick = d * 0.11
            UIBezierPath(roundedRect: CGRect(x: c - thick / 2, y: c - arm, width: thick, height: arm * 2),
                         cornerRadius: thick / 2).fill()
            UIBezierPath(roundedRect: CGRect(x: c - arm, y: c - thick / 2, width: arm * 2, height: thick),
                         cornerRadius: thick / 2).fill()
        }.withRenderingMode(.alwaysOriginal)
    }()

    var body: some View {
        beliTabs
        .environment(router)
        // Movie-palace atmosphere, app-wide and barely-there: a faint film
        // grain and a soft projector-beam vignette. Both sit beneath the
        // banners/toasts/celebrations added below, so those stay crisp.
        .filmGrain()
        .vignette()
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
        // Milestones, streaks, and other payoff moments rain confetti here —
        // above everything, never catching a touch.
        .overlay { CelebrationOverlay() }
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

    /// Beli's bar: a solid, opaque bottom bar with a top hairline and labeled
    /// icons. The center Search tab is a filled marquee disc (inline, not a
    /// floating FAB), and the Profile tab shows the user's own photo. Opaque
    /// on every OS — `CiniApp` configures `UITabBarAppearance` so iOS 26
    /// doesn't turn it into floating Liquid Glass.
    private var beliTabs: some View {
        // Custom binding so tapping the already-active tab is detected
        // (scroll-to-top) — the plain $selection binding can't see a re-tap.
        let selection = Binding<Tab>(
            get: { router.selection },
            set: { newValue in
                if newValue == router.selection {
                    router.tappedActiveTab(newValue)
                } else {
                    Haptics.tap()   // a soft tick on every tab change
                }
                router.selection = newValue
            }
        )
        return TabView(selection: selection) {
            FeedView()
                .tabItem { Label("Feed", systemImage: "newspaper") }
                .tag(Tab.feed)

            SwipeView()
                .tabItem { Label("Recs", systemImage: "rectangle.stack") }
                .tag(Tab.swipe)

            SearchView()
                .tabItem {
                    // .original so the disc stays marquee gold + white plus even
                    // when unselected — the center action always reads as "the"
                    // primary button, Beli-style.
                    Label { Text("Search") } icon: {
                        Image(uiImage: Self.searchTabIcon).renderingMode(.original)
                    }
                }
                .tag(Tab.search)

            YourListsView()
                .tabItem { Label("Your Lists", systemImage: "list.bullet") }
                .tag(Tab.lists)

            ProfileView()
                .tabItem {
                    if let profileTabIcon {
                        Label { Text("Profile") } icon: { Image(uiImage: profileTabIcon).renderingMode(.original) }
                    } else {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                }
                .tag(Tab.profile)
        }
        // Keep the Profile tab icon in sync with the user's avatar.
        .task(id: session.profile?.avatarURL) { await loadProfileTabIcon() }
    }

    private func loadProfileTabIcon() async {
        guard let url = session.profile?.avatarURL else {
            profileTabIcon = nil
            return
        }
        guard let image = await ImageLoader.shared.image(for: url) else { return }
        profileTabIcon = Self.circularTabIcon(image)
    }

    /// Center-crop an avatar into a circle sized for the tab bar. Returns an
    /// `.alwaysOriginal` image so the photo shows in full color (the tab bar
    /// won't tint or clip it for us).
    private static func circularTabIcon(_ image: UIImage, size: CGFloat = 29) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).addClip()
            let scale = max(size / image.size.width, size / image.size.height)
            let w = image.size.width * scale, h = image.size.height * scale
            image.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
        }.withRenderingMode(.alwaysOriginal)
    }
}

#Preview {
    RootTabView()
        .environment(AppSession())
        .environment(RankingStore())
}
