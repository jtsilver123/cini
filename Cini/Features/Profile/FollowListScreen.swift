import SwiftUI

/// Followers / Following — one connected screen with a tab for each,
/// pushed from the count rows on any profile. Same member-row treatment
/// as search results: avatar, name, @username, follow state, tap-through.
struct FollowListScreen: View {
    let userID: UUID
    @State var direction: SupabaseService.FollowDirection

    @Environment(AppSession.self) private var session
    @Environment(TabRouter.self) private var tabRouter

    @State private var members: [ProfileRow] = []
    @State private var iFollow: Set<UUID> = []
    @State private var requested: Set<UUID> = []
    @State private var followInFlight: Set<UUID> = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Followers | Following — flip without going back.
                HStack(spacing: 22) {
                    tabButton("Followers", .followers)
                    tabButton("Following", .following)
                    Spacer()
                }
                .padding(.bottom, 12)

                Button {
                    tabRouter.openMembersSearch = true
                    tabRouter.selection = .search
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(Theme.marquee)
                        Text("Find friends")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
                    }
                    .padding(12)
                    // Make the whole card tappable — the Spacer gap swallowed
                    // taps, so only the text/icons opened member search.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .floatingCard(cornerRadius: 16)
                .padding(.bottom, 12)

                if !loaded {
                    ListSkeleton(rows: 7)
                        .padding(.top, 8)
                }
                if members.isEmpty && loaded {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2").font(.title).foregroundStyle(Theme.gray)
                        Text(direction == .followers ? "No followers yet" : "Not following anyone yet")
                            .font(.subheadline.weight(.semibold))
                        Text(direction == .followers
                             ? "Share your profile so friends can find you."
                             : "Find friends in Search → Members.")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                ForEach(members) { member in
                    memberRow(member)
                    Divider()
                }
            }
            .padding(16)
        }
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: direction) { await load() }
        .refreshable { await load() }
    }

    private func tabButton(_ title: String, _ value: SupabaseService.FollowDirection) -> some View {
        let isOn = direction == value
        return Button {
            withAnimation(.snappy) {
                direction = value
                loaded = false
                members = []
            }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(isOn ? .bold : .regular))
                    .foregroundStyle(isOn ? Theme.ink : Theme.gray)
                Rectangle()
                    .fill(isOn ? Theme.ink : .clear)
                    .frame(height: 2)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private func memberRow(_ member: ProfileRow) -> some View {
        NavigationLink {
            MemberProfileView(userID: member.id, username: member.username)
        } label: {
            MemberRow(
                avatarURL: member.avatarUrl.flatMap(URL.init),
                title: firstName(member.displayName, member.username) ?? member.username,
                subtitle: "@\(member.username)"
            ) {
                if member.id != session.profile?.id {
                    let label = iFollow.contains(member.id) ? "Following"
                        : (requested.contains(member.id) ? "Requested" : "Follow")
                    PillButton(title: label, style: .outlined) {
                        Task { await toggleFollow(member.id) }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleFollow(_ id: UUID) async {
        // One in flight per member — rapid taps can't follow-then-unfollow.
        guard followInFlight.insert(id).inserted else { return }
        defer { followInFlight.remove(id) }
        Haptics.tap()
        // Optimistic flip, reverted if the call fails.
        if iFollow.contains(id) {
            iFollow.remove(id)
            do { try await SupabaseService.shared.unfollow(id) }
            catch { iFollow.insert(id); ToastCenter.shared.saveFailed() }
        } else if requested.contains(id) {
            // Tap "Requested" to withdraw a pending request to a private account.
            requested.remove(id)
            do { try await SupabaseService.shared.cancelFollowRequest(id) }
            catch { requested.insert(id); ToastCenter.shared.saveFailed() }
        } else {
            do {
                // Public follows instantly; private returns "requested" (pending).
                let result = try await SupabaseService.shared.requestFollow(id)
                if result == "requested" { requested.insert(id) } else { iFollow.insert(id) }
            }
            catch { ToastCenter.shared.saveFailed() }
        }
    }

    private func load() async {
        // Tag the load with its direction so a slow first tab can't land last
        // and overwrite the tab the user has since switched to.
        let d = direction
        let rows = (try? await SupabaseService.shared
            .followMembers(of: userID, direction: d)) ?? []
        // which of these do *I* already follow (for the button state)
        let mine = (try? await SupabaseService.shared.following()) ?? []
        guard d == direction else { return }
        members = rows
        iFollow = Set(mine.map(\.id))
        loaded = true
    }
}
