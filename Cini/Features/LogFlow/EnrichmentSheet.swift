import SwiftUI
import RankingEngine

/// Details card — appears right after "How was it?", before comparisons
/// (Beli's order): who you watched with, labels, notes, favorite
/// performances, watch date, personal notes, Stealth mode, then Okay to
/// move on to the head-to-head. Inputs collect into an EnrichmentDraft
/// the flow persists after the rank commits.
struct EnrichmentCard: View {
    let movie: Movie
    @Binding var draft: EnrichmentDraft
    /// True once comparisons begin — inputs stay visible but read-only.
    var isLocked = false
    var onOkay: () -> Void

    private let supabase = SupabaseService.shared

    /// Which editor is open — owned by LogFlowView, which presents the
    /// sheet at the top of the hierarchy (sheets attached deep inside the
    /// clear-background cover silently fail to present on device).
    @Binding var activeRow: Row?

    @State private var friendsCache = FriendsCache.shared
    @State private var friendScores: [FriendScoreRow] = []

    private var friends: [ProfileRow] { friendsCache.following }

    enum Row: String, Identifiable {
        case watchedWith, date, notes, performances
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            watchedWithSection
            divider
            watchedWhereSection
            divider
            enrichmentRow(.notes, icon: "square.and.pencil", title: "Add notes",
                          detail: draft.notes.isEmpty ? nil : draft.notes)
            divider
            enrichmentRow(.performances, icon: "star", title: "Add favorite performances",
                          detail: draft.cast.isEmpty ? nil : draft.cast.map(\.name).joined(separator: ", "))
            divider
            enrichmentRow(.date, icon: "calendar", title: "Add watch date",
                          detail: draft.watchDate?.formatted(date: .abbreviated, time: .omitted))
            divider
            stealthRow

            if !friendScores.isEmpty {
                divider
                friendsSection
            }

            if !isLocked {
                Button {
                    onOkay()
                } label: {
                    Text("Okay")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.marquee)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, isLocked ? 10 : 0)
        .frame(maxWidth: .infinity)
        .floatingCard()
        .task {
            friendsCache.refreshIfStale()   // chips render from cache instantly
            friendScores = (try? await supabase.friendScores(movieID: movie.tmdbID)) ?? []
        }
        // Opening the date editor makes the date theirs — stop managing it.
        .onChange(of: activeRow) { _, row in
            if row == .date { dateAutoFilled = false }
        }
    }

    private var divider: some View {
        Divider().overlay(Theme.hairline)
    }

    // MARK: Who did you watch with?

    /// Friends you tag most often, first; the chips are one-tap, and the
    /// chevron opens the full searchable multi-select picker.
    private var sortedFriends: [ProfileRow] { friendsCache.byTagFrequency }

    private var watchedWithSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard !isLocked else { return }
                activeRow = .watchedWith
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.2").frame(width: 28).foregroundStyle(Theme.ink)
                    Text("Who did you watch with?").foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
                }
            }
            .buttonStyle(.plain)
            if !friends.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sortedFriends) { friend in
                            let isOn = draft.watchedWith.contains(friend.id)
                            Button {
                                guard !isLocked else { return }
                                if isOn { draft.watchedWith.remove(friend.id) }
                                else { draft.watchedWith.insert(friend.id) }
                            } label: {
                                Text(friend.displayName.isEmpty ? friend.username : friend.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(isOn ? .white : Theme.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(isOn ? Theme.marquee : Theme.fill)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            } else {
                Text("Follow friends to tag them here.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
        }
        .padding(.vertical, 9)
    }

    // MARK: How did you watch it?

    /// Two one-tap chips, same treatment as the watched-with chips.
    private var watchedWhereSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "popcorn").frame(width: 28)
                Text("How did you watch it?")
                Spacer()
            }
            HStack(spacing: 8) {
                watchedWhereChip("At home", icon: "house", value: "home")
                watchedWhereChip("In theaters", icon: "ticket", value: "theater")
            }
        }
        .padding(.vertical, 9)
    }

    /// "In theaters" almost always means "watched today" — prefill the
    /// date quietly (it shows on the watch-date row, still editable) and
    /// take it back if they un-pick theaters without having touched it.
    @State private var dateAutoFilled = false

    private func watchedWhereChip(_ title: String, icon: String, value: String) -> some View {
        let isOn = draft.watchedWhere == value
        return Button {
            guard !isLocked else { return }
            draft.watchedWhere = isOn ? nil : value
            if value == "theater" {
                if !isOn && draft.watchDate == nil {
                    draft.watchDate = .now
                    dateAutoFilled = true
                } else if isOn && dateAutoFilled {
                    draft.watchDate = nil
                    dateAutoFilled = false
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.subheadline)
            }
            .foregroundStyle(isOn ? .white : Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn ? Theme.marquee : Theme.fill)
            )
        }
        .buttonStyle(.plain)
    }

    private func enrichmentRow(_ row: Row, icon: String, title: String, detail: String? = nil) -> some View {
        Button {
            guard !isLocked else { return }
            activeRow = row
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 28).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private var stealthRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock").frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stealth mode")
                Text("Hide this activity from the feed")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
            Spacer()
            Toggle("", isOn: $draft.stealthMode).labelsHidden().tint(Theme.marquee)
                .disabled(isLocked)
        }
        .padding(.vertical, 8)
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What your friends think")
                .font(.headline)
                .padding(.top, 12)
            ForEach(friendScores.prefix(3)) { friend in
                FriendThinkRow(friend: friend)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// One editor sheet per details row — presented by LogFlowView at the top
/// of the hierarchy so it reliably appears over the stacked cards.
struct EnrichmentRowSheet: View {
    let row: EnrichmentCard.Row
    @Binding var draft: EnrichmentDraft
    let cast: [CastMember]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch row {
                case .watchedWith:
                    WatchedWithPicker(selected: $draft.watchedWith)
                case .date:
                    DatePicker(
                        "Watch date",
                        selection: Binding(get: { draft.watchDate ?? .now }, set: { draft.watchDate = $0 }),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("Watch date")
                case .notes:
                    NoteEditor(title: "Notes", subtitle: "Visible to your friends", text: $draft.notes)
                case .performances:
                    CastPicker(cast: cast, selected: $draft.cast)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Sub-pickers

/// Full "Who did you watch with?" picker: multi-select over everyone you
/// follow, frequent movie companions first, with a search field.
struct WatchedWithPicker: View {
    @Binding var selected: Set<UUID>

    @State private var friendsCache = FriendsCache.shared
    @State private var query = ""

    private var visible: [ProfileRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return friendsCache.byTagFrequency.filter {
            q.isEmpty || $0.username.lowercased().contains(q)
                || $0.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                TextField("Search friends", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
            .listRowSeparator(.hidden)

            ForEach(visible) { friend in
                Button {
                    if selected.contains(friend.id) { selected.remove(friend.id) }
                    else { selected.insert(friend.id) }
                } label: {
                    MemberRow(
                        avatarURL: friend.avatarUrl.flatMap(URL.init),
                        title: friend.displayName.isEmpty ? friend.username : friend.displayName,
                        subtitle: "@\(friend.username)"
                    ) {
                        Image(systemName: selected.contains(friend.id)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected.contains(friend.id) ? Theme.marquee : Theme.gray)
                    }
                }
                .buttonStyle(.plain)
            }

            if friendsCache.following.isEmpty {
                Text("Follow friends from the Search tab to tag them here.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .listRowSeparator(.hidden)
            } else if visible.isEmpty {
                Text("No friends match “\(query)”.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Watched with")
        .navigationBarTitleDisplayMode(.inline)
        .task { friendsCache.refreshIfStale() }
    }
}

struct NoteEditor: View {
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle).font(.caption).foregroundStyle(Theme.gray)
            TextEditor(text: $text)
                .frame(minHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            Spacer()
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CastPicker: View {
    let cast: [CastMember]
    @Binding var selected: Set<CastMember>

    var body: some View {
        List(cast) { member in
            Button {
                if selected.contains(member) { selected.remove(member) } else { selected.insert(member) }
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: member.photoURL, size: 40)
                    VStack(alignment: .leading) {
                        Text(member.name).foregroundStyle(Theme.ink)
                        if let character = member.character {
                            Text(character).font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                    Spacer()
                    if selected.contains(member) {
                        Image(systemName: "checkmark").foregroundStyle(Theme.marquee)
                    }
                }
            }
        }
        .navigationTitle("Favorite Performances")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Friend row with avatar, username, score badge, notes, like + comment.
/// Tapping the identity opens their profile where navigation is available.
struct FriendThinkRow: View {
    let friend: FriendScoreRow
    var onOpenProfile: ((FriendScoreRow) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    onOpenProfile?(friend)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.displayName ?? friend.username).font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("@\(friend.username)").font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(onOpenProfile == nil)
                Spacer()
                ScoreBadge(score: friend.score, size: 44)
            }
            if let note = friend.note, !note.isEmpty {
                (Text("Notes: ").bold() + Text(note))
                    .font(.subheadline)
            }
            Text(friend.rankedAt.formatted(.dateTime.month(.wide).year()))
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
        .padding(.vertical, 6)
    }
}
