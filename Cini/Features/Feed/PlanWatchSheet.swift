import SwiftUI
import MessageUI
import EventKit

/// Plan to watch a title together with a friend — pick a time and send an
/// in-app invite (they Accept or propose another time), with an optional
/// "draft a text" shortcut. Opened from a watch-match push or the movie page's
/// "friends who want this" row.
struct PlanWatchSheet: View {
    let context: WatchPlanContext

    @Environment(\.dismiss) private var dismiss

    @State private var movie: Movie?
    /// The latest plan between us for this title (any direction), or nil.
    @State private var plan: WatchPlanRow?
    @State private var showTimePicker = false   // "suggest/change a time"
    @State private var when: Date = PlanWatchSheet.defaultTime()
    @State private var sending = false
    @State private var done = false
    /// The existing-plan lookup FAILED — showing the fresh-invite UI then
    /// would let a duplicate plan override an accepted one.
    @State private var loadFailed = false
    @State private var loadKey = 0
    @State private var doneMessage = ""
    @State private var showMessages = false

    /// Who's invited — starts with the friend the sheet was opened for;
    /// the picker in the invite card can add more.
    @State private var invitees: [MemberRef] = []

    private var friend: MemberRef { context.friend }
    private var myID: UUID? { SupabaseService.shared.currentUserID }

    /// Friends offered by the picker: the tapped friend first, then the
    /// user's follows in tag-frequency order (the order every picker uses).
    private var friendOptions: [MemberRef] {
        var options = [friend]
        for row in FriendsCache.shared.byTagFrequency where row.id != friend.id {
            options.append(MemberRef(id: row.id, username: row.username))
        }
        return options
    }

    /// "with @sam" / "with @sam + 2 friends" — whoever the plan involves.
    private var headerLine: String {
        let otherCount = plan.map { $0.others(besides: myID).count }
            ?? max(invitees.count, 1)
        return otherCount <= 1 ? "with @\(friend.username)"
                               : "with @\(friend.username) + \(otherCount - 1) friend\(otherCount == 2 ? "" : "s")"
    }

    /// Display name for anyone on the plan: the roster embed, the opened
    /// friend, the friends cache — in that order.
    private func memberName(_ id: UUID) -> String {
        if id == myID { return "You" }
        if id == friend.id { return "@\(friend.username)" }
        if let uname = plan?.memberList.first(where: { $0.userId == id })?.profile?.username {
            return "@\(uname)"
        }
        if let row = FriendsCache.shared.following.first(where: { $0.id == id }) {
            return "@\(row.username)"
        }
        return "a friend"
    }

    /// The plan's roster as display rows: every invitee + their response.
    private func rosterRows(_ plan: WatchPlanRow) -> [(name: String, status: String)] {
        plan.memberList
            .filter { $0.userId != myID }
            .map { (memberName($0.userId), $0.status) }
    }

    /// Per-friend status lines under a waiting/accepted card.
    @ViewBuilder
    private func rosterView(_ plan: WatchPlanRow) -> some View {
        let rows = rosterRows(plan)
        if rows.count > 1 || (rows.count == 1 && plan.proposerId == myID) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.name) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.status == "accepted" ? "checkmark.circle.fill"
                              : row.status == "declined" ? "xmark.circle" : "clock")
                            .foregroundStyle(row.status == "accepted" ? Theme.scoreGreen
                                             : row.status == "declined" ? Theme.scoreRed : Theme.gray)
                        Text(row.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(row.status == "accepted" ? "In"
                             : row.status == "declined" ? "Can't make it" : "Waiting")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// You can't plan a watch before the film exists: for unreleased titles
    /// the pickable range starts on release day, not today.
    private var dateFloor: Date {
        guard let movie, !movie.isReleased,
              let releaseDay = movie.releaseDateFull
                  .flatMap({ DateFormatter.localDay.date(from: $0) })
        else { return Date() }
        return max(Date(), releaseDay)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if done { doneCard } else { stateContent }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Movie night")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $showMessages) {
            MessageComposeView(body: draftText) { showMessages = false }
                .ignoresSafeArea()
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 14) {
            PosterView(url: movie?.posterURL, width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(movie?.title ?? "…")
                    .font(Theme.serif(20))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    AvatarView(url: nil, size: 22, name: friend.username)
                    Text(headerLine)
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    /// Show the right thing for the plan's state — never "Invite" when we're
    /// actually responding to one, or when a plan already exists.
    @ViewBuilder
    private var stateContent: some View {
        // The respond/waiting split keys on who suggested the CURRENT time
        // (lastProposer) — after a counter-propose the ball is back in the
        // original inviter's court, and they must get the Accept button.
        if loadFailed {
            retryState
        } else if let plan, plan.status == "accepted" {
            acceptedState(plan)
        } else if let plan, plan.status == "proposed", plan.currentProposerId == friend.id {
            respondState(plan)            // their suggested time — I respond
        } else if let plan, plan.status == "proposed", let myID, plan.currentProposerId == myID {
            waitingState(plan)            // my suggested time — waiting on them
        } else {
            planControls                  // no plan (or declined) → fresh invite
        }
    }

    /// They invited me — accept their time, suggest another, or pass.
    private func respondState(_ plan: WatchPlanRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HairlineCard {
                VStack(alignment: .leading, spacing: 10) {
                    let suggester = memberName(plan.currentProposerId)
                    if let at = plan.proposedAt {
                        Text("\(suggester) suggested \(at.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))")
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text("\(suggester) wants to watch this together")
                            .font(.subheadline.weight(.semibold))
                    }
                    // Group night? Say who else is on the invite.
                    let others = plan.others(besides: myID)
                        .filter { $0 != plan.currentProposerId }
                        .map { memberName($0) }
                    if !others.isEmpty {
                        Text("Also invited: \(others.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    PillButton(title: sending ? "…" : "Accept", systemImage: "checkmark") { accept(plan) }
                        .disabled(sending)
                }
            }
            Button { withAnimation(.snappy) { showTimePicker.toggle() } } label: {
                Label(showTimePicker ? "Hide" : "Suggest a different time", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)
            if showTimePicker { timeControls(send: { sendNewTime(plan) }, label: "Send new time") }
            Button("Can't make it", role: .destructive) { decline(plan) }
                .font(.subheadline).foregroundStyle(Theme.gray)
                .disabled(sending)
            draftTextButton
        }
    }

    /// I invited them — waiting; let me change the time.
    private func waitingState(_ plan: WatchPlanRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HairlineCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.badge.checkmark").foregroundStyle(Theme.marquee)
                        VStack(alignment: .leading, spacing: 2) {
                            let count = plan.memberList.count
                            Text(count > 1 ? "Invite sent to \(count) friends"
                                           : "Invite sent to @\(friend.username)")
                                .font(.subheadline.weight(.semibold))
                            if let at = plan.proposedAt {
                                Text(at.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                                    .font(.caption).foregroundStyle(Theme.gray)
                            }
                            Text(count > 1 ? "Waiting for them to confirm"
                                           : "Waiting for them to confirm")
                                .font(.caption).foregroundStyle(Theme.gray)
                        }
                        Spacer()
                    }
                    rosterView(plan)
                }
            }
            Button { withAnimation(.snappy) { showTimePicker.toggle() } } label: {
                Label(showTimePicker ? "Hide" : "Change the time", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)
            if showTimePicker { timeControls(send: { sendNewTime(plan) }, label: "Update time") }
            draftTextButton
        }
    }

    /// We're set.
    private func acceptedState(_ plan: WatchPlanRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HairlineCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.scoreGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            // Name whoever is actually IN (host + accepted
                            // members); pending friends show in the roster.
                            let confirmed = plan.others(besides: myID).filter {
                                $0 == plan.proposerId || plan.memberStatus($0) == "accepted"
                            }.map { memberName($0) }
                            Text("You're watching with \(confirmed.isEmpty ? "@\(friend.username)" : confirmed.joined(separator: ", "))")
                                .font(.subheadline.weight(.semibold))
                            if let at = plan.proposedAt {
                                Text(at.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                                    .font(.caption).foregroundStyle(Theme.gray)
                            }
                        }
                        Spacer()
                    }
                    rosterView(plan)
                }
            }
            if plan.proposedAt != nil {
                addToCalendarButton(plan)
            }
            draftTextButton
        }
    }

    /// The plan is locked in — put it on the real calendar. Write-only
    /// EventKit access (iOS 17+), so Cini never reads existing events.
    private func addToCalendarButton(_ plan: WatchPlanRow) -> some View {
        Button {
            Task { await addToCalendar(plan) }
        } label: {
            Label("Add to Calendar", systemImage: "calendar.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(Capsule().strokeBorder(Theme.marquee.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private func addToCalendar(_ plan: WatchPlanRow) async {
        guard let at = plan.proposedAt else { return }
        let eventStore = EKEventStore()
        let granted = (try? await eventStore.requestWriteOnlyAccessToEvents()) ?? false
        guard granted else {
            ToastCenter.shared.show("Calendar access is off for Cini — allow it in Settings.")
            return
        }
        let event = EKEvent(eventStore: eventStore)
        let others = plan.others(besides: myID)
            .filter { $0 == plan.proposerId || plan.memberStatus($0) == "accepted" }
            .map { memberName($0) }
        event.title = "🎬 \(movie?.title ?? "Movie night") with \(others.isEmpty ? "@\(friend.username)" : others.joined(separator: ", "))"
        event.startDate = at
        event.endDate = at.addingTimeInterval(2 * 3600)
        event.notes = "Planned on Cini"
        event.calendar = eventStore.defaultCalendarForNewEvents
        do {
            try eventStore.save(event, span: .thisEvent)
            Haptics.success()
            ToastCenter.shared.show("Added to your calendar 🗓️")
        } catch {
            ToastCenter.shared.show("Couldn't add it to your calendar — try again.")
        }
    }

    /// The existing-plan check failed — retry rather than risking a
    /// duplicate invite over a plan we couldn't see.
    private var retryState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HairlineCard {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.gray)
                    Text("Couldn't check for an existing plan — try again.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                    Spacer()
                }
            }
            PillButton(title: "Try again", systemImage: "arrow.clockwise") { loadKey += 1 }
        }
    }

    private var planControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            inviteePicker
            timeControls(send: { sendInvite() },
                         label: invitees.count <= 1
                             ? "Send invite to @\(friend.username)"
                             : "Send invite to \(invitees.count) friends")
            draftTextButton
        }
    }

    /// Movie night scales past two: tap friends to add them to the invite.
    private var inviteePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who's coming?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(friendOptions) { option in
                        let on = invitees.contains(option)
                        Button {
                            Haptics.tap()
                            if on {
                                // Never empty: the last friend stays.
                                if invitees.count > 1 { invitees.removeAll { $0 == option } }
                            } else {
                                invitees.append(option)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                                Text("@\(option.username)")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .background(Capsule().fill(on ? Theme.marquee : Theme.fill))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(on ? "Remove @\(option.username) from the invite"
                                               : "Add @\(option.username) to the invite")
                    }
                }
            }
        }
    }

    /// Time presets + picker + a primary send button (reused by every state).
    private func timeControls(send: @escaping () -> Void, label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When works?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 8) {
                // Presets that fall before an unreleased film's opening day
                // just don't appear — you can't plan "Tonight" for a film
                // that opens next month.
                quickChip("Tonight", Self.at(20, daysFromNow: 0))
                quickChip("Tomorrow", Self.at(20, daysFromNow: 1))
                quickChip("Weekend", Self.nextSaturday())
                if dateFloor > Date() {
                    quickChip("Opening night", Self.eveningOf(dateFloor))
                }
            }
            DatePicker("", selection: $when, in: dateFloor...,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
            PillButton(title: sending ? "Sending…" : label, systemImage: "paperplane.fill") { send() }
                .disabled(sending)
        }
    }

    private var draftTextButton: some View {
        Button {
            if MFMessageComposeViewController.canSendText() {
                showMessages = true
            } else {
                ToastCenter.shared.show("Texting isn't available on this device.")
            }
        } label: {
            Label("Draft a text", systemImage: "message.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(Capsule().strokeBorder(Theme.marquee.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private var doneCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle).foregroundStyle(Theme.scoreGreen)
            Text(doneMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            PillButton(title: "Done") { dismiss() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func quickChip(_ label: String, _ date: Date) -> some View {
        // A preset before the film's release day would offer an impossible
        // plan — skip it (the DatePicker floor guards manual picks).
        if date >= Calendar.current.startOfDay(for: dateFloor) {
            quickChipBody(label, date)
        }
    }

    private func quickChipBody(_ label: String, _ date: Date) -> some View {
        Button {
            Haptics.tap()
            // Never propose a time in the past (e.g. "Tonight" tapped after 8pm).
            when = max(date, max(Date(), dateFloor))
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Calendar.current.isDate(when, equalTo: date, toGranularity: .minute) ? Theme.background : Theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Calendar.current.isDate(when, equalTo: date, toGranularity: .minute) ? Theme.marquee : Theme.fill))
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func load() async {
        // Seed the invite with the friend the sheet was opened for, and warm
        // the friends cache so the picker has the rest.
        if invitees.isEmpty { invitees = [friend] }
        FriendsCache.shared.refreshIfStale()
        if let m = (try? await SupabaseService.shared.movies(ids: [context.movieID]))?.first?.asMovie {
            movie = m
        } else if let m = try? await TMDBService.shared.details(for: context.movieID) {
            // Cache miss (e.g. opened from a push) — fall back to TMDB so the
            // header shows the real title instead of staying on "…".
            movie = m
        }
        // The latest plan in either direction drives which UI we show. A FAILED
        // lookup is not "no plan" — flag it so the UI offers retry instead of
        // a fresh invite that could stomp an accepted plan.
        do {
            plan = try await SupabaseService.shared.latestWatchPlan(movieID: context.movieID, withUser: friend.id)
            loadFailed = false
        } catch {
            if !Task.isCancelled { loadFailed = true }
        }
        if let at = plan?.proposedAt, at > Date() { when = at }
        // Unreleased film: the default "tonight at 8" would be before its
        // opening — move the selection up to opening night.
        if when < dateFloor { when = Self.eveningOf(dateFloor) }
    }

    private func sendNewTime(_ plan: WatchPlanRow) {
        sending = true
        Task {
            do {
                try await SupabaseService.shared.respondWatchPlan(planID: plan.id, accept: true, newTime: when)
                Haptics.success()
                doneMessage = "New time sent to @\(friend.username)."
                withAnimation(.snappy) { done = true }
            } catch { ToastCenter.shared.saveFailed() }
            sending = false
        }
    }

    private func decline(_ plan: WatchPlanRow) {
        guard !sending else { return }
        sending = true
        Task {
            do {
                try await SupabaseService.shared.respondWatchPlan(planID: plan.id, accept: false)
                Haptics.tap()
                ToastCenter.shared.show("Replied — they'll see you can't make it 👍")
                dismiss()
            } catch {
                // Don't dismiss as if it worked — the inviter would still be waiting.
                ToastCenter.shared.saveFailed()
            }
            sending = false
        }
    }

    private func sendInvite() {
        guard !sending, !invitees.isEmpty else { return }
        sending = true
        Task {
            do {
                let planID = try await SupabaseService.shared.proposeWatchPlan(
                    movieID: context.movieID,
                    inviteeIDs: invitees.map(\.id),
                    proposedAt: when)
                // nil = the server filtered every invitee (blocked/unknown) —
                // nothing was sent, so don't pretend it was.
                guard planID != nil else {
                    ToastCenter.shared.show("Couldn't send that invite.")
                    sending = false
                    return
                }
                Haptics.success()
                doneMessage = invitees.count == 1
                    ? "Invite sent to @\(friend.username). They'll get a nudge to confirm."
                    : "Invite sent to \(invitees.count) friends. Each gets a nudge to confirm."
                withAnimation(.snappy) { done = true }
            } catch {
                ToastCenter.shared.saveFailed()
            }
            sending = false
        }
    }

    private func accept(_ plan: WatchPlanRow) {
        guard !sending else { return }
        sending = true
        Task {
            do {
                try await SupabaseService.shared.respondWatchPlan(planID: plan.id, accept: true)
                Haptics.success()
                doneMessage = "You're set — see you and @\(friend.username) at the movies 🍿"
                withAnimation(.snappy) { done = true }
            } catch {
                ToastCenter.shared.saveFailed()
            }
            sending = false
        }
    }

    private var draftText: String {
        let title = movie?.title ?? "a movie"
        return "Want to watch \(title) together? I'm planning it on Cini 🎬 \(AppLinks.appStore)"
    }

    // MARK: Time helpers

    static func defaultTime() -> Date { at(20, daysFromNow: 0) }

    /// 8pm on the given day (opening-night default for unreleased titles).
    static func eveningOf(_ day: Date) -> Date {
        Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: day) ?? day
    }

    static func at(_ hour: Int, daysFromNow days: Int) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    static func nextSaturday() -> Date {
        let cal = Calendar.current
        var date = at(20, daysFromNow: 0)
        for _ in 0..<7 {
            // Saturday, but never in the past — if it's already Saturday evening,
            // roll to next week so "Weekend" can't propose a time that's gone.
            if cal.component(.weekday, from: date) == 7 && date > Date() { return date }   // 7 = Saturday
            date = cal.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }
}

/// Thin wrapper over the system Messages composer for the "draft a text" path.
struct MessageComposeView: UIViewControllerRepresentable {
    let body: String
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
