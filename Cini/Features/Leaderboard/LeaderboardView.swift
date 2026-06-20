import SwiftUI
import Contacts

/// Serif "Leaderboard" header, Invite pill, Watched/Influence/Notes/Photos
/// metric control, genre filter, and ranked rows with taste-match lines.
struct LeaderboardView: View {
    @Environment(AppSession.self) private var session

    @State private var metric = 0
    @State private var genre: String?
    @State private var rows: [LeaderboardRow] = []
    @State private var showInvite = false
    @State private var loaded = false

    // One row per metric so the label, query key, and caption can never drift
    // out of sync (a mismatched parallel array would crash on index).
    private struct Metric { let name: String; let key: String; let copy: String }
    private let metricDefs: [Metric] = [
        Metric(name: "Watched", key: "watched", copy: "Number of movies on your watched list"),
        Metric(name: "Influence", key: "influence", copy: "How often a friend bookmarks something to Want to Watch after you rank it"),
        Metric(name: "Notes", key: "notes", copy: "Number of public notes you've written"),
    ]
    private var metrics: [String] { metricDefs.map(\.name) }
    private var currentMetric: Metric { metricDefs[min(metric, metricDefs.count - 1)] }

    var body: some View {
        NavigationStack {
            // Header and controls stay frozen; only the rankings scroll.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    SegmentedPillControl(segments: metrics, selection: $metric)
                        .onChange(of: metric) { _, _ in Task { await load() } }

                    Text(currentMetric.copy)
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)

                    filters
                }
                .screenHPadding()
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(Theme.background)
                ScrollView {
                    rankedRows
                        .screenHPadding()
                }
                .refreshable { await load() }
            }
            .nativeContentWidth()
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
                                .truncationMode(.middle)
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
                    // Make the WHOLE row tappable, not just the avatar/text —
                    // the Spacer gap has no content to hit-test without this.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < rows.count - 1 { Divider() }   // no dangling line after the last row
            }

            if rows.isEmpty {
                if !loaded {
                    ListSkeleton(rows: 8)
                        .padding(.top, 8)
                } else {
                    EmptyStateView(
                        icon: "trophy.fill",
                        title: "Start the race",
                        message: "No rankings yet — invite friends and see whose taste wins.",
                        actionTitle: "Invite friends") { showInvite = true }
                }
            }
        }
    }

    private func load() async {
        rows = (try? await SupabaseService.shared.leaderboard(
            metric: currentMetric.key, genre: genre)) ?? []
        loaded = true
    }
}

// MARK: - Invite sheet (growth loop)

struct InviteSheet: View {
    /// When true the contact list loads itself as the sheet appears (used from
    /// the feed's unlock card so the list is pre-populated). Elsewhere the user
    /// taps "Find friends" first.
    var autoFindContacts = false

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var contacts: [PhoneContact] = []
    @State private var contactMembers: [SuggestedMember] = []
    @State private var contactsChecked = false
    @State private var loadingContacts = false
    @State private var autoTried = false
    @State private var followed: Set<UUID> = []
    @State private var query = ""
    @State private var showShare = false
    /// Phone digits we've already texted an invite to — persisted so a contact
    /// who never joined shows "Remind" (and a gentler nudge) on a later visit.
    @AppStorage("cini.invitedPhones") private var invitedPhonesRaw = ""

    private var inviteURL: String {
        AppLinks.invite(session.profile?.username ?? "")
    }
    private var inviteText: String {
        "Join me on Cini — we rank every movie & show head-to-head 🎬\n\(inviteURL)"
    }
    private var reminderText: String {
        "Still want in on Cini? Here's my invite 🎬\n\(inviteURL)"
    }
    private func phoneDigits(_ p: String) -> String { p.filter(\.isNumber) }
    private func isInvited(_ contact: PhoneContact) -> Bool {
        invitedPhonesRaw.split(separator: ",").map(String.init).contains(phoneDigits(contact.phone))
    }
    private func markInvited(_ contact: PhoneContact) {
        let d = phoneDigits(contact.phone)
        guard !d.isEmpty, !isInvited(contact) else { return }
        invitedPhonesRaw += invitedPhonesRaw.isEmpty ? d : ",\(d)"
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
            .task {
                // Pre-populate the list when asked, unless contacts were already
                // denied — then leave the "Find friends" button so they can opt in.
                guard autoFindContacts, !autoTried, !contactsChecked else { return }
                autoTried = true
                if CNContactStore.authorizationStatus(for: .contacts) != .denied {
                    await loadContacts()
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(Theme.gray).padding(.top, 4)
    }

    private var shareLinkRow: some View {
        Button { Haptics.tap(); showShare = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up").font(.title3).foregroundStyle(Theme.background)
                    .frame(width: 40, height: 40).background(Circle().fill(Theme.marquee))
                Text("Share your invite link").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private var findContactsButton: some View {
        Button { Haptics.tap(); Task { await loadContacts() } } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill").font(.title3).foregroundStyle(Theme.marquee)
                Text(loadingContacts ? "Finding friends…" : "Find friends from your contacts")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if loadingContacts { ProgressView() }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(loadingContacts)
    }

    private func memberRow(_ member: SuggestedMember) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: member.avatarUrl.flatMap(URL.init), size: 44,
                       name: member.displayName.isEmpty ? member.username : member.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(firstName(member.displayName, member.username) ?? member.username)
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
            let invited = isInvited(contact)
            PillButton(title: invited ? "Remind" : "Invite",
                       style: invited ? .outlined : .filled) { inviteContact(contact) }
        }
    }

    private func loadContacts() async {
        loadingContacts = true
        let people = await ContactsList.fetch()
        let emails = await ContactsEmails.fetch()
        // Match on both email and phone, then de-dupe by member id.
        let byEmail = (try? await SupabaseService.shared.membersFromEmails(emails)) ?? []
        let byPhone = (try? await SupabaseService.shared.membersFromPhones(people.map(\.phone))) ?? []
        // Remember these contacts (as hashes only) so the user gets pinged when
        // one of them joins Cini later.
        await SupabaseService.shared.storeContacts(people.map(\.phone))
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
        // Already texted once → send the gentler reminder copy instead.
        let body = isInvited(contact) ? reminderText : inviteText
        // urlQueryValueEncoded escapes the "&" in "movie & show" — otherwise it
        // truncates the SMS body and drops the invite link.
        if let url = URL(string: "sms:\(digits)&body=\(body.urlQueryValueEncoded)") { openURL(url) }
        markInvited(contact)
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
