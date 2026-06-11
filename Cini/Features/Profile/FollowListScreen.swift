import SwiftUI

/// Followers / Following — pushed from the count row on any profile.
/// Same member-row treatment as search results: avatar, name, @username,
/// follow state, tap-through to the profile.
struct FollowListScreen: View {
    let userID: UUID
    let direction: SupabaseService.FollowDirection

    @Environment(AppSession.self) private var session
    @Environment(TabRouter.self) private var tabRouter

    @State private var members: [ProfileRow] = []
    @State private var iFollow: Set<UUID> = []
    @State private var loaded = false

    private var title: String { direction == .followers ? "Followers" : "Following" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
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
        if iFollow.contains(id) {
            iFollow.remove(id)
            try? await SupabaseService.shared.unfollow(id)
        } else {
            iFollow.insert(id)
            try? await SupabaseService.shared.follow(id)
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
