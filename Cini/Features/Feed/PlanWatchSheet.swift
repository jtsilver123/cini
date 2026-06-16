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
    /// A proposal the friend already sent ME (so I can Accept instead of re-ask).
    @State private var incomingPlan: WatchPlanRow?
    @State private var when: Date = PlanWatchSheet.defaultTime()
    @State private var sending = false
    @State private var done = false
    @State private var doneMessage = ""
    @State private var showMessages = false

    private var friend: MemberRef { context.friend }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if done {
                        doneCard
                    } else {
                        if let incomingPlan, let at = incomingPlan.proposedAt {
                            incomingProposal(incomingPlan, at)
                            Text("…or suggest a different time")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.gray)
                        }
                        planControls
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Movie night")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
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

    private func incomingProposal(_ plan: WatchPlanRow, _ at: Date) -> some View {
        HairlineCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("@\(friend.username) suggested \(at.formatted(.dateTime.weekday(.wide).hour().minute()))")
                    .font(.subheadline.weight(.semibold))
                PillButton(title: "That works — accept") { accept(plan) }
            }
        }
    }

    private var planControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When works?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            // Quick presets, then a precise picker.
            HStack(spacing: 8) {
                quickChip("Tonight", Self.at(20, daysFromNow: 0))
                quickChip("Tomorrow", Self.at(20, daysFromNow: 1))
                quickChip("Weekend", Self.nextSaturday())
            }
            DatePicker("", selection: $when, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)

            PillButton(title: sending ? "Sending…" : "Send invite to @\(friend.username)",
                       systemImage: "paperplane.fill") { sendInvite() }
                .disabled(sending)

            // Optional: pull the friend in over text too.
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
            when = date
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
        }
        // Show "Accept" only when THEY proposed to ME and it's still open.
        if let plan = try? await SupabaseService.shared.latestWatchPlan(movieID: context.movieID, withUser: friend.id),
           plan.status == "proposed", plan.proposerId == friend.id {
            incomingPlan = plan
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
        Task {
            do {
                try await SupabaseService.shared.respondWatchPlan(planID: plan.id, accept: true)
                Haptics.success()
                doneMessage = "You're set — see you and @\(friend.username) at the movies 🍿"
                withAnimation(.snappy) { done = true }
            } catch {
                ToastCenter.shared.saveFailed()
            }
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
            if cal.component(.weekday, from: date) == 7 { return date }   // 7 = Saturday
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
