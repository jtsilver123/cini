import SwiftUI
import UniformTypeIdentifiers
import MessageUI

/// Letterboxd / IMDb import. Accepts the actual Letterboxd export ZIP
/// (or any single CSV), matches every title against TMDB with live
/// progress, auto-imports the Letterboxd watchlist, and seeds the
/// persistent "Movies you may have seen" ranking queue — favorites first.
struct LetterboxdImportView: View {
    /// Entry points that promise "paste a list" land directly on the
    /// paste sheet instead of the full import picker.
    var startWithPaste = false

    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The import itself runs app-wide in ImportRunner — this screen just
    /// starts imports and renders the runner's state, so closing it (or
    /// browsing the app) never kills a half-done import.
    @State private var runner = ImportRunner.shared
    @State private var phase: Phase = .pick
    @State private var transferCode: String?
    @State private var transferTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showPicker = false
    @State private var showPaste = false
    @State private var pastedText = ""
    @State private var pasteDestination: PasteDestination = .watched
    @State private var linkCopied = false
    @State private var mailDraft: MailDraft?
    /// Files the server has received so far on this transfer code — shown
    /// live while waiting (a two-file transfer lands one at a time).
    @State private var receivedCount = 0
    /// Where the one-tap import email landed — confirmation line under the
    /// waiting card. nil = copy-link path (or the send fell back to Mail).
    @State private var emailedTo: String?

    enum Phase {
        case pick, working, summary
    }

    enum PasteDestination: String, CaseIterable, Identifiable {
        case watched = "I've watched these"
        case wantToWatch = "I want to watch these"
        var id: String { rawValue }
    }

    /// This screen's phase mirrors the app-wide runner — opening it during
    /// a background import lands on live progress; after one, the summary.
    private func syncPhase(with state: ImportRunner.RunState) {
        switch state {
        case .running: phase = .working
        case .done: phase = .summary
        case .failed(let message):
            errorMessage = message
            phase = .pick
            runner.acknowledge()
        case .idle:
            if phase == .working { phase = .pick }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .pick: pickStep
                case .working: workingStep
                case .summary: summaryStep
                }
            }
            .background(Theme.background)
            .swipeDismissesKeyboard()
            .onAppear {
                ImportTransfer.viewIsHandling = true
                if startWithPaste { showPaste = true }
                syncPhase(with: runner.state)
                // Reopened while a desktop transfer is pending? Resume watching
                // it — this screen blocks the app-wide watcher while open, so
                // NOT polling here would deadlock the handoff.
                if transferTask == nil, let pending = ImportTransfer.pendingCode {
                    transferCode = pending
                    startPolling(code: pending)
                }
            }
            .onDisappear {
                ImportTransfer.viewIsHandling = false
                transferTask?.cancel()
                transferTask = nil   // so a reappear knows to resume polling
                // The runner keeps importing — that's the point.
            }
            .onChange(of: runner.state) { _, newState in
                withAnimation(.snappy) { syncPhase(with: newState) }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .working {
                    // A stuck import must never trap the user…
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop") {
                            runner.cancel()
                            transferTask?.cancel()
                            withAnimation(.snappy) { phase = .pick }
                        }
                    }
                    // …and neither should a HEALTHY one: Hide keeps it
                    // running in the background (status chip tracks it).
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Hide") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(phase == .summary ? "Done" : "Cancel") {
                            if phase == .summary { runner.acknowledge() }
                            dismiss()
                        }
                    }
                }
            }
            .sheet(item: $mailDraft) { draft in
                MailComposeView(draft: draft)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPaste) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Copy your movie list in Notes, then paste it here — one title per line. Bullets, numbering, and years like \"Dune (2021)\" all work.")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                            TextEditor(text: $pastedText)
                                .frame(minHeight: 220)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                            Picker("Where do these go?", selection: $pasteDestination) {
                                ForEach(PasteDestination.allCases) { destination in
                                    Text(destination.rawValue).tag(destination)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text(pasteDestination == .watched
                                 ? "They'll be saved for you to rank head-to-head — favorites first."
                                 : "They'll land straight on your Want to Watch list.")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .navigationTitle("Paste from Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showPaste = false }
                        }
                    }
                    // Keep "Import list" tappable above the keyboard.
                    .safeAreaInset(edge: .bottom) {
                        PillButton(title: "Import list") {
                            showPaste = false
                            errorMessage = nil
                            runner.startText(pastedText,
                                             toWatchlist: pasteDestination == .wantToWatch,
                                             store: store)
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .padding()
                        .background(.thinMaterial)
                    }
                }
                .presentationDetents([.large])
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.zip, .commaSeparatedText, .plainText]
            ) { pickResult in
                switch pickResult {
                case .success(let url):
                    errorMessage = nil
                    runner.startFiles([url], store: store)
                case .failure:
                    // iOS failed to hand us the file — say so instead of leaving
                    // the user on a silent pick screen wondering what happened.
                    Haptics.error()
                    errorMessage = "Couldn't open that file — try again, or paste your list instead."
                }
            }
        }
    }

    // MARK: Step 1 — pick the file

    private var pickStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                ImportHandoffBadge()
                    .padding(.top, 28)
                Text("Bring your history")
                    .font(Theme.serif(30))
                Text("Takes about a minute. Import from Letterboxd, IMDb, or Netflix — the export can be a .zip or a .csv, both work. Easiest on a computer, so we'll email you a link.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                desktopCard

                HStack(spacing: 22) {
                    Button {
                        showPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("Already have the file?").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                    Button {
                        showPaste = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "note.text")
                            Text("Paste a list").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                }

                if !ImportHistory.all().isEmpty {
                    NavigationLink {
                        ImportHistoryScreen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Past imports").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                }

                Text("Star ratings are never copied — on Cini your scores come from head-to-head ranking. We only use them to pick which titles you rank first.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.scoreRed)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
        }
    }

    // MARK: Step 2 — progress

    private var workingStep: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView(value: runner.progressFraction)
                .progressViewStyle(.linear)
                .tint(Theme.marquee)
                .padding(.horizontal, 48)
            Text(runner.progressText)
                .font(.subheadline.weight(.semibold))
            // A live estimate once the matching rate settles; the generic
            // line covers the ramp-up and the non-matching phases.
            Text(runner.etaText ?? "Matching every title against TMDB — big libraries take a minute.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
            Text("You can keep using Cini — tap Hide and we'll finish in the background.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Step 3 — summary

    private var summaryStep: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.scoreGreen)
                    .padding(.top, 24)
                Text("Import complete")
                    .font(Theme.serif(30))

                if let result = runner.result {
                    VStack(spacing: 0) {
                        if runner.pastedToWatchlist {
                            summaryRow(icon: "bookmark.fill", count: result.watched.count,
                                       label: "added to Want to Watch",
                                       detail: "Find them under My Lists → Want to Watch.")
                        } else {
                            summaryRow(icon: "film.stack", count: result.watched.count,
                                       label: "films waiting to rank",
                                       detail: "Find them under My Lists → Watched → Pending — your favorites are first.")
                            Divider()
                            summaryRow(icon: "bookmark.fill", count: result.watchlist.count,
                                       label: "saved to Want to Watch")
                            if !result.stillWatching.isEmpty {
                                Divider()
                                summaryRow(icon: "play.tv", count: result.stillWatching.count,
                                           label: "shows you're still watching",
                                           detail: "Marked as Currently Watching — rank them when you finish.")
                            }
                        }
                        let reviewCount = result.watched.filter { $0.imported.review != nil }.count
                        if reviewCount > 0 {
                            Divider()
                            if runner.detailsImportFailed {
                                summaryRow(icon: "exclamationmark.triangle", count: reviewCount,
                                           label: "reviews didn't come over",
                                           detail: "Run the same import again to retry — nothing else is affected.")
                            } else {
                                summaryRow(icon: "square.and.pencil", count: reviewCount,
                                           label: "reviews brought over",
                                           detail: "Each one shows under Your Details on its movie page.")
                            }
                        }
                        if !result.importedLists.isEmpty {
                            Divider()
                            summaryRow(icon: "list.star", count: result.importedLists.count,
                                       label: "lists brought over",
                                       detail: result.importedLists.map(\.name)
                                           .joined(separator: ", "))
                        }
                        if !result.unmatched.isEmpty {
                            Divider()
                            summaryRow(icon: "questionmark.circle", count: result.unmatched.count,
                                       label: "couldn't be matched",
                                       detail: result.unmatched.prefix(5).map(\.title).joined(separator: ", ")
                                           + (result.unmatched.count > 5 ? "…" : ""))
                        }
                        if !result.errored.isEmpty {
                            Divider()
                            summaryRow(icon: "wifi.exclamationmark", count: result.errored.count,
                                       label: "couldn't be checked (connection trouble)",
                                       detail: "Run the import again to pick these up — already-imported titles are never duplicated.")
                        }
                    }
                    .padding(.vertical, 4)
                    .floatingCard()
                }

                PillButton(title: pendingToRank ? "Start ranking" : "Done",
                           systemImage: pendingToRank ? "arrow.right" : "checkmark") {
                    // Land in My Lists → Watched, where the freshly-queued titles
                    // wait to be ranked (CIN-26). Watchlist-only imports just close.
                    if pendingToRank {
                        TabRouter.shared.pendingListsTab = .watched
                        TabRouter.shared.selection = .lists
                    }
                    runner.acknowledge()
                    dismiss()
                }
            }
            .padding(20)
        }
    }

    /// True when the import queued titles to rank (so "Start ranking" should
    /// jump to My Lists → Watched). Watchlist-only/pasted imports don't.
    private var pendingToRank: Bool {
        !runner.pastedToWatchlist && !(runner.result?.watched.isEmpty ?? true)
    }

    private func summaryRow(icon: String, count: Int, label: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).foregroundStyle(Theme.marquee).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) \(label)").font(.subheadline.weight(.bold))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.gray)
                }
            }
            Spacer()
        }
        .padding(14)
    }

    // MARK: Desktop transfer - export on a computer, beam it here

    private var importPageURL: String { "https://trycini.com/import/" }

    @ViewBuilder
    private var desktopCard: some View {
        HairlineCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(Theme.marquee)
                    Text("Import from your computer")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("~1 MIN")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.5)
                        .foregroundStyle(Theme.onMarquee)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.marquee))
                }
                if let transferCode {
                    if let emailedTo {
                        Label {
                            Text("Link sent to \(emailedTo)")
                                .font(.caption.weight(.semibold))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(Theme.scoreGreen)
                    }
                    Text("Open your email on your computer, tap your link, and drop in your export — it lands here automatically.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(receivedCount > 0
                             ? "\(receivedCount) file\(receivedCount == 1 ? "" : "s") received — finishing the transfer…"
                             : "Waiting for your upload… link works for 30 minutes")
                            .font(.caption2)
                            .foregroundStyle(receivedCount > 0 ? Theme.marquee : Theme.gray)
                    }
                    HStack(spacing: 22) {
                        Button {
                            Task {
                                await sendLinkEmail(code: transferCode)
                                if emailedTo != nil { ToastCenter.shared.show("Sent again 📬") }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "envelope")
                                Text("Resend email").font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Theme.marquee)
                        }
                        .buttonStyle(.plain)
                        Button {
                            UIPasteboard.general.string = transferLink(code: transferCode)
                            linkCopied = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: linkCopied ? "checkmark" : "link")
                                Text(linkCopied ? "Link copied" : "Copy the link")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Theme.marquee)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    // Backup: compose it yourself — handy when the link
                    // should go to a DIFFERENT address than your account's.
                    Button {
                        if MFMailComposeViewController.canSendMail() {
                            mailDraft = MailDraft(subject: Self.emailSubject,
                                                  htmlBody: emailHTMLBody(code: transferCode))
                        } else {
                            openURL(emailMyselfURL(code: transferCode))
                        }
                    } label: {
                        Text("Or email it yourself — to any address")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label { Text("We email you your private import link") } icon: {
                            Text("1").bold().foregroundStyle(Theme.marquee)
                        }
                        Label { Text("Open it on your computer and follow two steps") } icon: {
                            Text("2").bold().foregroundStyle(Theme.marquee)
                        }
                        Label { Text("Your movies land here by themselves") } icon: {
                            Text("3").bold().foregroundStyle(Theme.marquee)
                        }
                    }
                    .font(.subheadline)
                    PillButton(title: "Email me the link", systemImage: "envelope") {
                        Task { await startDesktopTransfer(thenOpenEmail: true) }
                    }
                    .frame(maxWidth: .infinity)
                    Button {
                        Task { await startDesktopTransfer(thenOpenEmail: false) }
                    } label: {
                        Text("No email handy? Copy the link instead")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The link carries the first name so the import page can confirm
    /// WHOSE phone it's linked to ("Linked to Jake's Cini app").
    private func transferLink(code: String) -> String {
        var link = "\(importPageURL)?code=\(code)"
        let name = session.profile.flatMap { firstName($0.displayName, $0.username) }
        if let name, !name.isEmpty {
            link += "&name=\(name.urlQueryValueEncoded)"
        }
        return link
    }

    private static let emailSubject = "Your Cini import link"

    /// Rich HTML body (bold links/steps) for the in-app composer.
    private func emailHTMLBody(code: String) -> String {
        let link = transferLink(code: code)
        // Don't hard-code a near-black text color: in Mail's dark-mode compose
        // (and any dark-mode mail client) that renders dark-on-dark and the body
        // disappears. Declaring color-scheme lets the client pick a readable
        // adaptive text color — dark on light, light on dark — instead.
        return """
        <div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color-scheme:light dark;">
          <p>Open this link <b>on your computer</b> to bring your history into Cini:</p>
          <p><a href="\(link)" style="font-weight:700;">\(link)</a></p>
          <ol>
            <li>Open the link on your computer.</li>
            <li>Grab your export from <b>Letterboxd</b>, <b>IMDb</b>, or <b>Netflix</b> and drop it in.</li>
            <li>Your movies and shows beam straight to Cini on your phone.</li>
          </ol>
          <p style="font-size:13px;opacity:0.65;"><i>This link works for 30 minutes — grab a fresh one in the app if it expires.</i></p>
        </div>
        """
    }

    /// Plain-text fallback (mailto can't do bold) when no Mail account is set up.
    private func emailMyselfURL(code: String) -> URL {
        let body = [
            "Open this link on your computer to import your history:",
            "",
            transferLink(code: code),
            "",
            "It walks you through grabbing your Letterboxd, IMDb, or Netflix export and beams it straight to Cini on your phone. (Link works for 30 minutes — grab a fresh one in the app if it expires.)",
        ].joined(separator: "\n")
        var components = URLComponents(string: "mailto:")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: Self.emailSubject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? URL(string: "mailto:")!
    }

    private func startDesktopTransfer(thenOpenEmail: Bool) async {
        guard let code = try? await SupabaseService.shared.createImportCode() else {
            errorMessage = "Couldn't start a transfer - check your connection."
            return
        }
        errorMessage = nil
        transferCode = code
        // Persist the handoff so a landed upload is caught app-wide, even if
        // this screen closes before the computer side finishes.
        ImportTransfer.begin(code)
        linkCopied = false
        emailedTo = nil
        if thenOpenEmail {
            await sendLinkEmail(code: code)
        } else {
            UIPasteboard.general.string = transferLink(code: code)
            linkCopied = true
        }
        startPolling(code: code)
    }

    /// One tap → the server emails the link to the user's own inbox
    /// (hello@trycini.com via Resend). Only if that fails do we fall back
    /// to the old compose-it-yourself path.
    private func sendLinkEmail(code: String) async {
        let name = session.profile.flatMap { firstName($0.displayName, $0.username) }
        if let to = try? await SupabaseService.shared.sendImportLinkEmail(
            code: code, firstName: name) {
            emailedTo = to
            Haptics.tap()
            return
        }
        // Server send failed (offline, phone-only account with no email…) —
        // the composer still gets the link across.
        if MFMailComposeViewController.canSendMail() {
            mailDraft = MailDraft(subject: Self.emailSubject,
                                  htmlBody: emailHTMLBody(code: code),
                                  to: SupabaseService.shared.currentEmail.map { [$0] } ?? [])
        } else {
            openURL(emailMyselfURL(code: code))
        }
    }

    /// Watch the transfer code until the upload lands (checking immediately,
    /// then every 3s for the code's 30-minute window). The code also persists
    /// in `ImportTransfer` so RootTabView's watcher picks the upload up even
    /// if this screen is closed or the phone locks meanwhile.
    private func startPolling(code: String) {
        transferTask?.cancel()
        receivedCount = 0
        transferTask = Task {
            for _ in 0..<600 {
                guard !Task.isCancelled else { return }
                let (ready, paths) = await SupabaseService.shared.importUploadState(code: code)
                if ready {
                    transferCode = nil
                    runner.startFromStorage(paths: paths, store: store)
                    return
                }
                // A first file has landed (two-file transfers upload one at a
                // time) — reflect it instead of a generic "waiting".
                receivedCount = paths.count
                try? await Task.sleep(for: .seconds(3))
            }
            transferCode = nil
            ImportTransfer.clear()
            errorMessage = "That link expired — email yourself a fresh one."
        }
    }

}

// MARK: - Import history

/// Every past import on this device: when, what landed, and — expandable —
/// exactly which titles couldn't be matched, so nothing vanishes silently.
struct ImportHistoryScreen: View {
    private let entries = ImportHistory.all()

    var body: some View {
        List {
            ForEach(entries) { entry in
                Section(entry.date.formatted(date: .abbreviated, time: .shortened)) {
                    if entry.toRank > 0 {
                        statRow(icon: "film.stack", text: "\(entry.toRank) films waiting to rank")
                    }
                    if entry.saved > 0 {
                        statRow(icon: "bookmark.fill", text: "\(entry.saved) saved to Want to Watch")
                    }
                    if entry.reviews > 0 {
                        statRow(icon: "square.and.pencil",
                                text: entry.detailsFailed
                                    ? "\(entry.reviews) reviews (some didn't come over)"
                                    : "\(entry.reviews) reviews brought over")
                    }
                    if entry.lists > 0 {
                        statRow(icon: "list.star", text: "\(entry.lists) list\(entry.lists == 1 ? "" : "s") rebuilt")
                    }
                    if let watching = entry.watching, watching > 0 {
                        statRow(icon: "play.tv", text: "\(watching) show\(watching == 1 ? "" : "s") marked still watching")
                    }
                    if entry.unmatched.isEmpty {
                        statRow(icon: "checkmark.circle", text: "Every title matched")
                    } else {
                        DisclosureGroup {
                            ForEach(entry.unmatched, id: \.self) { title in
                                Text(title)
                                    .font(.caption)
                                    .foregroundStyle(Theme.gray)
                            }
                        } label: {
                            statRow(icon: "questionmark.circle",
                                    text: "\(entry.unmatched.count) couldn't be matched")
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Past imports")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if entries.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath",
                               title: "No imports yet",
                               message: "Your past imports and their results will show up here.")
            }
        }
    }

    private func statRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.marquee).frame(width: 24)
            Text(text).font(.subheadline)
        }
    }
}

// MARK: - Letterboxd → Cini, in one glance

/// The import's promise as a picture: the source marks (Letterboxd's three
/// dots + Netflix's red "N"), an arrow, and the Cini ticket. (Marks are drawn
/// natively — no trademarked asset ships in the bundle.)
struct ImportHandoffBadge: View {
    var body: some View {
        HStack(spacing: 12) {
            // The sources stack vertically so it reads as "your services," not
            // a flow chart of two separate inputs.
            VStack(spacing: 8) {
                // Letterboxd — the three-dot mark.
                HStack(spacing: -6) {
                    Circle().fill(Color(red: 1.00, green: 0.50, blue: 0.00))
                        .frame(width: 20, height: 20)
                    Circle().fill(Color(red: 0.00, green: 0.88, blue: 0.33))
                        .frame(width: 20, height: 20)
                    Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96))
                        .frame(width: 20, height: 20)
                }
                .frame(width: 64, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.surface))
                // Netflix — the red "N" on black.
                Text("N")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Color(red: 0.90, green: 0.09, blue: 0.16))
                    .frame(width: 64, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.black))
            }

            Image(systemName: "arrow.right")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.gray)

            Text("cini")
                .font(Theme.display(22))
                .foregroundStyle(Theme.marquee)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.marquee.opacity(0.55), lineWidth: 1)))
        }
        .accessibilityLabel("Import from Letterboxd or Netflix into Cini")
    }
}

// MARK: - Native mail composer (HTML so the import email can use bold)

struct MailDraft: Identifiable {
    let id = UUID()
    let subject: String
    let htmlBody: String
    var to: [String] = []
}

/// Wraps `MFMailComposeViewController` so the import link can go out as a
/// formatted HTML email (bold link + steps) instead of a flat mailto.
struct MailComposeView: UIViewControllerRepresentable {
    let draft: MailDraft
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(draft.subject)
        if !draft.to.isEmpty { vc.setToRecipients(draft.to) }
        vc.setMessageBody(draft.htmlBody, isHTML: true)
        return vc
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            dismiss()
        }
    }
}
