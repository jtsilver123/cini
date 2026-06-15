import SwiftUI

/// Serif "Leaderboard" header, Invite pill, Watched/Influence/Notes/Photos
/// metric control, genre filter, and ranked rows with taste-match lines.
struct LeaderboardView: View {
    @Environment(AppSession.self) private var session

    @State private var metric = 0
    @State private var genre: String?
    @State private var rows: [LeaderboardRow] = []
    @State private var showInvite = false
    @State private var loaded = false

    private let metrics = ["Watched", "Influence", "Notes"]
    private let metricKeys = ["watched", "influence", "notes"]
    private let metricCopy = [
        "Number of movies on your watched list",
        "How often your rankings convert to friends' watchlist adds",
        "Number of public notes you've written",
    ]

    var body: some View {
        NavigationStack {
            // Header and controls stay frozen; only the rankings scroll.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    SegmentedPillControl(segments: metrics, selection: $metric)
                        .onChange(of: metric) { _, _ in Task { await load() } }

                    Text(metricCopy[metric])
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)

                    filters
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(Theme.background)
                ScrollView {
                    rankedRows
                        .padding(.horizontal, 16)
                }
                .refreshable { await load() }
            }
            .background(Theme.background)
            .task { await load() }
            .sheet(isPresented: $showInvite) {
                InviteSheet()
                    .presentationDetents([.large])
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Leaderboard").font(Theme.pageHeader)
            Spacer()
            PillButton(title: "Invite", systemImage: "person.badge.plus") {
                showInvite = true
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Menu {
                Button("All Genres") { genre = nil; Task { await load() } }
                ForEach(["Drama", "Comedy", "Sci-Fi", "Horror", "Action", "Romance", "Thriller"], id: \.self) { g in
                    Button(g) { genre = g; Task { await load() } }
                }
            } label: {
                FilterPill(title: genre ?? "All Genres")
            }
        }
    }

    private var rankedRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                NavigationLink {
                    MemberProfileView(userID: row.userId, username: row.username)
                } label: {
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.title3)
                            .foregroundStyle(Theme.gray)
                            .frame(width: 28, alignment: .leading)
                        AvatarView(url: row.avatarUrl.flatMap(URL.init), size: 48, name: row.username)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(row.username)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            if let pct = row.matchPct {
                                Text("+\(Int(pct))% Match")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.scoreGreen)
                            }
                        }
                        Spacer()
                        Text("\(row.value)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider()
            }

            if rows.isEmpty {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "trophy")
                            .font(.title2)
                            .foregroundStyle(Theme.gray)
                        Text("No rankings yet — invite friends to start the race.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                            .multilineTextAlignment(.center)
                        PillButton(title: "Invite friends", systemImage: "person.badge.plus") {
                            showInvite = true
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    private func load() async {
        rows = (try? await SupabaseService.shared.leaderboard(
            metric: metricKeys[metric], genre: genre)) ?? []
        loaded = true
    }
}

// MARK: - Invite sheet (growth loop)

struct InviteSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var contacts: [PhoneContact] = []
    @State private var contactMembers: [SuggestedMember] = []
    @State private var contactsChecked = false
    @State private var loadingContacts = false
    @State private var followed: Set<UUID> = []
    @State private var query = ""
    @State private var showShare = false

    private var inviteURL: String {
        AppLinks.invite(session.profile?.username ?? "")
    }
    private var inviteText: String {
        "Join me on Cini — we rank every movie & show head-to-head 🎬\n\(inviteURL)"
    }
    private var filteredContacts: [PhoneContact] {
        query.isEmpty ? contacts
            : contacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Lazy so a large address book doesn't render every row at once
                // (that's what made this screen feel glitchy while scrolling).
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Inviting friends has perks")
                            .font(Theme.serif(30)).foregroundStyle(Theme.ink)
                        Text("Every friend who joins with your link earns you a credit to unlock a feature — Average Scores, Social Links, or Stealth Mode. You'll follow each other automatically.")
                            .font(.subheadline).foregroundStyle(Theme.gray)
                    }

                    shareLinkRow

                    if !contacts.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                            TextField("Search your contacts", text: $query)
                                .autocorrectionDisabled()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                    }

                    if !contactMembers.isEmpty {
                        sectionHeader("ALREADY ON CINI")
                        ForEach(contactMembers) { member in memberRow(member) }
                    }

                    if contactsChecked {
                        if !filteredContacts.isEmpty {
                            sectionHeader("INVITE YOUR CONTACTS")
                            ForEach(filteredContacts) { contact in contactRow(contact) }
                        } else if contactMembers.isEmpty {
                            Text("No contacts to show.")
                                .font(.subheadline).foregroundStyle(Theme.gray)
                        }
                    } else {
                        findContactsButton
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Invite friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showShare) { ActivityShareSheet(items: [inviteText]) }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(Theme.gray).padding(.top, 4)
    }

    private var shareLinkRow: some View {
        Button { showShare = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up").font(.title3).foregroundStyle(Theme.background)
                    .frame(width: 40, height: 40).background(Circle().fill(Theme.marquee))
                Text("Share your invite link").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private var findContactsButton: some View {
        Button { Task { await loadContacts() } } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill").font(.title3).foregroundStyle(Theme.marquee)
                Text(loadingContacts ? "Finding friends…" : "Find friends from your contacts")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if loadingContacts { ProgressView() }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(loadingContacts)
    }

    private func memberRow(_ member: SuggestedMember) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: member.avatarUrl.flatMap(URL.init), size: 44,
                       name: member.displayName.isEmpty ? member.username : member.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName.isEmpty ? member.username : member.displayName)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("@\(member.username)").font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
            }
            Spacer()
            PillButton(title: followed.contains(member.id) ? "Following" : "Follow",
                       style: followed.contains(member.id) ? .outlined : .filled) {
                Task { await toggleFollow(member.id) }
            }
        }
    }

    private func contactRow(_ contact: PhoneContact) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.surface2).frame(width: 44, height: 44)
                .overlay(Text(initials(contact.name)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.gray))
            Text(contact.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer()
            PillButton(title: "Invite", style: .filled) { inviteContact(contact) }
        }
    }

    private func loadContacts() async {
        loadingContacts = true
        let people = await ContactsList.fetch()
        let emails = await ContactsEmails.fetch()
        // Match on both email and phone, then de-dupe by member id.
        let byEmail = (try? await SupabaseService.shared.membersFromEmails(emails)) ?? []
        let byPhone = (try? await SupabaseService.shared.membersFromPhones(people.map(\.phone))) ?? []
        var seen = Set<UUID>()
        contactMembers = (byEmail + byPhone).filter { seen.insert($0.id).inserted }
        contacts = people
        contactsChecked = true
        loadingContacts = false
    }

    private func toggleFollow(_ id: UUID) async {
        if followed.contains(id) {
            followed.remove(id)
            try? await SupabaseService.shared.unfollow(id)
        } else {
            followed.insert(id)
            do { try await SupabaseService.shared.requestFollow(id) }
            catch { followed.remove(id); ToastCenter.shared.saveFailed() }
        }
    }

    private func inviteContact(_ contact: PhoneContact) {
        Haptics.tap()
        let digits = contact.phone.filter { $0.isNumber || $0 == "+" }
        // urlQueryValueEncoded escapes the "&" in "movie & show" — otherwise it
        // truncates the SMS body and drops the invite link.
        if let url = URL(string: "sms:\(digits)&body=\(inviteText.urlQueryValueEncoded)") { openURL(url) }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

// MARK: - Other member's profile — same UI as your own.

struct MemberProfileView: View {
    let userID: UUID
    let username: String

    var body: some View {
        ProfileScreen(userID: userID, username: username)
    }
}
