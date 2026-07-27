import SwiftUI

/// Per-type notification controls. Muting is enforced server-side at
/// creation time, so a muted type sends neither a push nor a bell entry.
struct NotificationPreferencesView: View {

    /// Grouped per-type controls. Kinds match the notifications table.
    private static let sections: [(title: String, items: [(kind: String, label: String, detail: String)])] = [
        ("Activity on your stuff", [
            ("like", "Likes", "A friend likes your activity"),
            ("comment", "Comments", "A friend comments on your activity"),
            ("mention", "Mentions", "A friend @mentions you in a comment"),
            ("saved_your_rank", "Saved from your taste",
             "A friend adds a title you ranked to their Want to Watch"),
            ("friend_ranked_watchlist_movie", "Want to Watch ranked by a friend",
             "A friend ranks a movie on your Want to Watch list"),
        ]),
        ("People", [
            ("new_follower", "New followers", "Someone starts following you"),
            ("contact_joined", "Contacts joining", "Someone from your contacts joins Cini"),
            ("invite_joined", "Invites accepted", "Someone joins Cini with your username"),
            ("friend_loved", "Friend ranked a favorite", "A friend ranks a movie or show you love"),
            ("crew_added", "Crew invites", "A friend adds you to their crew"),
        ]),
        ("Recommendations", [
            ("tonight_pick", "Tonight's Pick", "A daily pick to watch, sent each evening"),
            ("direct_rec", "Recs from friends", "A friend recommends a movie directly to you"),
            ("rec_request", "Rec requests", "A friend asks you to recommend them something"),
            ("rec_watched", "Recs watched", "A friend ranks something you recommended"),
            ("rec_passed", "Recs passed on", "A friend passes on something you recommended"),
        ]),
        ("Watch together", [
            ("watch_match", "Watch matches", "You and a friend both want to watch the same title"),
            ("watch_invite", "Watch invites", "A friend invites you to watch something together"),
            ("friend_watching", "Friends watching", "A friend starts a show you're also watching"),
            ("caught_up", "Caught up", "A friend catches up on a show you're watching"),
        ]),
        ("Reminders", [
            ("rate_nudge", "Rank reminders", "A nudge to rank a saved title once it's out to watch"),
            ("post_watch_nudge", "After movie night", "The morning after a watch plan — how was it?"),
            ("weekly_recap", "Weekly recap", "A Sunday wrap-up of your week on Cini"),
            ("streak_reminder", "Streak reminders", "A weekly heads-up before your streak resets"),
        ]),
        ("Releases & availability", [
            ("watchlist_showing", "Playing near you",
             "A Want to Watch movie hits theaters near your saved zipcode"),
            ("streaming_now", "Streaming alerts", "A saved title you asked about starts streaming"),
            ("season_premiere", "New seasons", "A show you ranked returns with a new season"),
        ]),
    ]

    @State private var muted: Set<String> = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            ForEach(Self.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items, id: \.kind) { entry in
                        Toggle(isOn: binding(for: entry.kind)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.gray)
                            }
                        }
                        .tint(Theme.velvet)
                        .disabled(!loaded)
                    }
                }
            }

            Section {
                Text("Whether alerts appear as banners or stay silent is up to iOS — manage that in Settings → Notifications → Cini.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.scoreRed)
                    .listRowBackground(Color.clear)
            }

            if loadFailed {
                Section {
                    Button("Couldn't load your settings — tap to retry") {
                        Task { await loadMuted() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.marquee)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: SupabaseService.shared.currentUserID) {
            await loadMuted()
        }
    }

    /// Toggles stay disabled until the server state actually loads: a failed
    /// read must not render everything "on" — the next toggle write replaces
    /// the whole muted array and would wipe the user's other mutes.
    private func loadMuted() async {
        do {
            muted = try await SupabaseService.shared.mutedNotificationKinds()
            loaded = true
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func binding(for kind: String) -> Binding<Bool> {
        Binding(
            get: { !muted.contains(kind) },
            set: { enabled in
                errorMessage = nil
                let previous = muted
                if enabled { muted.remove(kind) } else { muted.insert(kind) }
                Task {
                    do {
                        // Atomic per-kind flip server-side — a whole-array
                        // write raced the theater page's toggle (and other
                        // devices) and clobbered their changes.
                        try await SupabaseService.shared.setNotificationKindMuted(kind, muted: !enabled)
                    } catch {
                        muted = previous   // roll the switch back on failure
                        errorMessage = "Couldn't save — check your connection."
                    }
                }
            }
        )
    }
}
