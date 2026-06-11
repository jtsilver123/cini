import SwiftUI

/// Followers / Following — pushed from the count row on any profile.
/// Same member-row treatment as search results: avatar, name, @username,
/// follow state, tap-through to the profile.
struct FollowListScreen: View {
    let userID: UUID
    let direction: SupabaseService.FollowDirection

    @Environment(AppSession.self) private var session

    @State private var members: [ProfileRow] = []
    @State private var iFollow: Set<UUID> = []
    @State private var loaded = false

    private var title: String { direction == .followers ? "Followers" : "Following" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
            HStack(spacing: 12) {
                AvatarView(url: member.avatarUrl.flatMap(URL.init), size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName.isEmpty ? member.username : member.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("@\(member.username)")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                }
                Spacer()
                if member.id != session.profile?.id {
                    PillButton(title: iFollow.contains(member.id) ? "Following" : "Follow",
                               style: .outlined) {
                        Task { await toggleFollow(member.id) }
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
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
