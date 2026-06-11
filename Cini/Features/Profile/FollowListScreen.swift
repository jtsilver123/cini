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
                }
                .buttonStyle(.plain)
                .floatingCard(cornerRadius: 14)
                .padding(.bottom, 12)

                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
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
        .background(Theme.background)
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: direction == .followers) { await load() }
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
                title: member.displayName.isEmpty ? member.username : member.displayName,
                subtitle: "@\(member.username)"
            ) {
                if member.id != session.profile?.id {
                    PillButton(title: iFollow.contains(member.id) ? "Following" : "Follow",
                               style: .outlined) {
                        Task { await toggleFollow(member.id) }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleFollow(_ id: UUID) async {
        // Optimistic flip, reverted if the call fails.
        if iFollow.contains(id) {
            iFollow.remove(id)
            do { try await SupabaseService.shared.unfollow(id) }
            catch { iFollow.insert(id) }
        } else {
            iFollow.insert(id)
            do { try await SupabaseService.shared.follow(id) }
            catch { iFollow.remove(id) }
        }
    }

    private func load() async {
        members = (try? await SupabaseService.shared
            .followMembers(of: userID, direction: direction)) ?? []
        // which of these do *I* already follow (for the button state)
        let mine = (try? await SupabaseService.shared.following()) ?? []
        iFollow = Set(mine.map(\.id))
        loaded = true
    }
}
