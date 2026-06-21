import SwiftUI
import MessageUI

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
    @State private var doneMessage = ""
    @State private var showMessages = false

    private var friend: MemberRef { context.friend }
    private var myID: UUID? { SupabaseService.shared.currentUserID }

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
        .task { await load() }
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
                    Text("with @\(friend.username)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                }
            }
            Spacer()
        }
    }

    /// Show the right thing for the plan's state — never "Invite" when we're
    /// actually responding to one, or when a plan already exists.
    @ViewBuilder
    private var stateContent: some View {
        if let plan, plan.status == "accepted" {
            acceptedState(plan)
        } else if let plan, plan.status == "proposed", plan.proposerId == friend.id {
            respondState(plan)            // they invited me
        } else if let plan, plan.status == "proposed", let myID, plan.proposerId == myID {
            waitingState(plan)            // I invited them
        } else {
            planControls                  // no plan (or declined) → fresh invite
        }
    }

    /// They invited me — accept their time, suggest another, or pass.
    private func respondState(_ plan: WatchPlanRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HairlineCard {
                VStack(alignment: .leading, spacing: 10) {
                    if let at = plan.proposedAt {
                        Text("@\(friend.username) suggested \(at.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))")
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text("@\(friend.username) wants to watch this together")
                            .font(.subheadline.weight(.semibold))
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
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge.checkmark").foregroundStyle(Theme.marquee)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite sent to @\(friend.username)").font(.subheadline.weight(.semibold))
                        if let at = plan.proposedAt {
                            Text(at.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                                .font(.caption).foregroundStyle(Theme.gray)
                        }
                        Text("Waiting for them to confirm").font(.caption).foregroundStyle(Theme.gray)
                    }
                    Spacer()
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
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.scoreGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're watching with @\(friend.username)").font(.subheadline.weight(.semibold))
                        if let at = plan.proposedAt {
                            Text(at.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                                .font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                    Spacer()
                }
            }
            draftTextButton
        }
    }

    private var planControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            timeControls(send: { sendInvite() },
                         label: "Send invite to @\(friend.username)")
            draftTextButton
        }
    }

    /// Time presets + picker + a primary send button (reused by every state).
    private func timeControls(send: @escaping () -> Void, label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When works?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 8) {
                quickChip("Tonight", Self.at(20, daysFromNow: 0))
                quickChip("Tomorrow", Self.at(20, daysFromNow: 1))
                quickChip("Weekend", Self.nextSaturday())
            }
            DatePicker("", selection: $when, in: Date()...,
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

    private func quickChip(_ label: String, _ date: Date) -> some View {
        Button {
            Haptics.tap()
            // Never propose a time in the past (e.g. "Tonight" tapped after 8pm).
            when = max(date, Date())
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
        if let m = (try? await SupabaseService.shared.movies(ids: [context.movieID]))?.first?.asMovie {
            movie = m
        } else if let m = try? await TMDBService.shared.details(for: context.movieID) {
            // Cache miss (e.g. opened from a push) — fall back to TMDB so the
            // header shows the real title instead of staying on "…".
            movie = m
        }
        // The latest plan in either direction drives which UI we show.
        plan = try? await SupabaseService.shared.latestWatchPlan(movieID: context.movieID, withUser: friend.id)
        if let at = plan?.proposedAt, at > Date() { when = at }
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
        sending = true
        Task {
            do {
                try await SupabaseService.shared.proposeWatchPlan(
                    movieID: context.movieID, inviteeID: friend.id, proposedAt: when)
                Haptics.success()
                doneMessage = "Invite sent to @\(friend.username). They'll get a nudge to confirm."
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
