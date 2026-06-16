import SwiftUI

/// Per-type notification controls. Muting is enforced server-side at
/// creation time, so a muted type sends neither a push nor a bell entry.
struct NotificationPreferencesView: View {

    /// Grouped per-type controls. Kinds match the notifications table.
    private static let sections: [(title: String, items: [(kind: String, label: String, detail: String)])] = [
        ("Activity on your stuff", [
            ("like", "Likes", "A friend likes your activity"),
            ("comment", "Comments", "A friend comments on your activity"),
            ("saved_your_rank", "Saved from your taste",
             "A friend adds a title you ranked to their Want to Watch"),
            ("friend_ranked_watchlist_movie", "Want to Watch ranked by a friend",
             "A friend ranks a movie on your Want to Watch list"),
        ]),
        ("People", [
            ("new_follower", "New followers", "Someone starts following you"),
            ("contact_joined", "Contacts joining", "Someone from your contacts joins Cini"),
            ("invite_joined", "Invites accepted", "Someone joins Cini with your username"),
            ("friend_loved", "Friend rated a favorite", "A friend rates a movie or show you love"),
        ]),
        ("Recommendations", [
            ("tonight_pick", "Tonight's Pick", "A daily pick to watch, sent each evening"),
            ("direct_rec", "Recs from friends", "A friend recommends a movie directly to you"),
            ("rec_request", "Rec requests", "A friend asks you to recommend them something"),
        ]),
        ("Reminders", [
            ("rate_nudge", "Rate reminders", "A nudge to rank a saved title once it's out to watch"),
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
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            muted = await SupabaseService.shared.mutedNotificationKinds()
            loaded = true
        }
    }

    private func binding(for kind: String) -> Binding<Bool> {
        Binding(
            get: { !muted.contains(kind) },
            set: { enabled in
                errorMessage = nil
                let previous = muted
                if enabled { muted.remove(kind) } else { muted.insert(kind) }
                let snapshot = muted
                Task {
                    do {
                        try await SupabaseService.shared.setMutedNotificationKinds(snapshot)
                    } catch {
                        muted = previous   // roll the switch back on failure
                        errorMessage = "Couldn't save — check your connection."
                    }
                }
            }
        )
    }
}
