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

    @State private var phase: Phase = .pick
    // Watchlist always comes along now (the toggle was removed) — Letterboxd
    // watchlist → your Want to Watch list.
    private let importWatchlist = true
    @State private var result: LetterboxdImporter.Result?
    @State private var transferCode: String?
    @State private var transferTask: Task<Void, Never>?
    @State private var progressText = ""
    @State private var progressFraction: Double = 0
    @State private var errorMessage: String?
    @State private var showPicker = false
    @State private var showPaste = false
    @State private var pastedText = ""
    @State private var pasteDestination: PasteDestination = .watched
    @State private var pastedToWatchlist = false
    @State private var detailsImportFailed = false
    @State private var importTask: Task<Void, Never>?
    @State private var linkCopied = false
    @State private var mailDraft: MailDraft?

    enum Phase {
        case pick, working, summary
    }

    enum PasteDestination: String, CaseIterable, Identifiable {
        case watched = "I've watched these"
        case wantToWatch = "I want to watch these"
        var id: String { rawValue }
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
            .onAppear { if startWithPaste { showPaste = true } }
            .onDisappear { transferTask?.cancel() }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .working {
                    // A stuck import must never trap the user.
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop") {
                            importTask?.cancel()
                            withAnimation(.snappy) { phase = .pick }
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(phase == .summary ? "Done" : "Cancel") { dismiss() }
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
                                 ? "They'll join your ranking queue so you can score them head-to-head."
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
                            Task { await runPastedImport() }
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
                if case .success(let url) = pickResult {
                    importTask = Task { await runImport(from: url) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .working)
    }

    // MARK: Step 1 — pick the file

    private var pickStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                ImportHandoffBadge()
                    .padding(.top, 28)
                Text("Bring your history")
                    .font(Theme.serif(30))
                Text("Takes about 1 minute. Bring your history from Letterboxd, IMDb, or Netflix — the export works best from a computer, so email yourself a link, do it there, and it beams straight to your phone.")
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

                Text("Star ratings are never copied — on Cini your list comes from head-to-head ranking. We just use them to order your queue.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
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
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(Theme.marquee)
                .padding(.horizontal, 48)
            Text(progressText)
                .font(.subheadline.weight(.semibold))
            Text("Matching every title against TMDB — big libraries take a minute.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
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

                if let result {
                    VStack(spacing: 0) {
                        if pastedToWatchlist {
                            summaryRow(icon: "bookmark.fill", count: result.watched.count,
                                       label: "added to Want to Watch",
                                       detail: "Find them under My Lists → Want to Watch.")
                        } else {
                            summaryRow(icon: "film.stack", count: result.watched.count,
                                       label: "films queued to rank",
                                       detail: "Find them under My Lists → Watched → Pending — your favorites are first.")
                            Divider()
                            summaryRow(icon: "bookmark.fill", count: importWatchlist ? result.watchlist.count : 0,
                                       label: "saved to Want to Watch",
                                       detail: importWatchlist ? nil : "Watchlist import was off.")
                        }
                        let reviewCount = result.watched.filter { $0.imported.review != nil }.count
                        if reviewCount > 0 {
                            Divider()
                            if detailsImportFailed {
                                summaryRow(icon: "exclamationmark.triangle", count: reviewCount,
                                           label: "reviews couldn't sync",
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
                    dismiss()
                }
            }
            .padding(20)
        }
    }

    /// True when the import queued titles to rank (so "Start ranking" should
    /// jump to My Lists → Watched). Watchlist-only/pasted imports don't.
    private var pendingToRank: Bool {
        !pastedToWatchlist && !(result?.watched.isEmpty ?? true)
    }

    private func summaryRow(icon: String, count: Int, label: String, detail: String?) -> some View {
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

    // MARK: Pipeline

    private func runPastedImport() async {
        errorMessage = nil
        withAnimation(.snappy) { phase = .working }
        progressText = "Reading your list…"
        progressFraction = 0
        do {
            let outcome = try await LetterboxdImporter.runText(pastedText) { progress in
                switch progress {
                case .reading:
                    progressText = "Reading your list…"
                case .matching(let done, let total):
                    progressText = "Matching \(done) of \(total)"
                    progressFraction = Double(done) / Double(max(total, 1))
                }
            }
            pastedToWatchlist = pasteDestination == .wantToWatch
            if pastedToWatchlist {
                for match in outcome.watched
                where !store.isOnWatchlist(match.movie.tmdbID) && !store.isWatched(match.movie.tmdbID) {
                    await store.toggleWatchlist(movie: match.movie)
                }
            } else {
                ImportQueue.shared.seed(with: outcome.watched, store: store)
            }
            result = outcome
            Haptics.success()
            ToastCenter.shared.show(successLine(for: outcome))
            withAnimation(.snappy) { phase = .summary }
        } catch {
            Haptics.error()
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't read that list."
            withAnimation(.snappy) { phase = .pick }
        }
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
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.marquee))
                }
                if let transferCode {
                    Text("Check your email on your computer, open your link, and drop in your export — it lands here automatically.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your upload… link works for 30 minutes")
                            .font(.caption2)
                            .foregroundStyle(Theme.gray)
                    }
                    HStack(spacing: 22) {
                        Button {
                            openURL(emailMyselfURL(code: transferCode))
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
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label { Text("Email yourself your private import link") } icon: {
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
        let name = session.profile.map {
            $0.displayName.split(separator: " ").first.map(String.init) ?? $0.username
        }
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
        linkCopied = false
        if thenOpenEmail {
            // The in-app composer lets us send a nicely formatted (bold) email;
            // fall back to a plain mailto if no Mail account is set up.
            if MFMailComposeViewController.canSendMail() {
                mailDraft = MailDraft(subject: Self.emailSubject,
                                      htmlBody: emailHTMLBody(code: code),
                                      to: SupabaseService.shared.currentEmail.map { [$0] } ?? [])
            } else {
                openURL(emailMyselfURL(code: code))
            }
        } else {
            UIPasteboard.general.string = transferLink(code: code)
            linkCopied = true
        }
        transferTask?.cancel()
        transferTask = Task {
            // Poll for the upload until the code's 30-minute window closes.
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if let path = await SupabaseService.shared.importUploadPath(code: code) {
                    await importFromStorage(path: path)
                    return
                }
            }
            transferCode = nil
            errorMessage = "That link expired — email yourself a fresh one."
        }
    }

    private func importFromStorage(path: String) async {
        do {
            Haptics.tap()
            ToastCenter.shared.show("Your export landed — importing now 🎬")
            let data = try await SupabaseService.shared.downloadImport(path: path)
            let filename = (path as NSString).lastPathComponent
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            try data.write(to: tempURL)
            transferCode = nil
            await runImport(from: tempURL)
        } catch {
            errorMessage = "Got your file but couldn't read it - try again."
        }
    }

    private func runImport(from url: URL) async {
        errorMessage = nil
        pastedToWatchlist = false
        withAnimation(.snappy) { phase = .working }
        progressText = "Reading export…"
        progressFraction = 0

        do {
            let outcome = try await LetterboxdImporter.run(fileURL: url) { progress in
                switch progress {
                case .reading:
                    progressText = "Reading export…"
                case .matching(let done, let total):
                    progressText = "Matching \(done) of \(total)"
                    progressFraction = Double(done) / Double(max(total, 1))
                }
            }

            // Seed the persistent ranking queue (favorites first).
            ImportQueue.shared.seed(with: outcome.watched, store: store)

            // Reviews → Your Details notes; diary dates (every rewatch) →
            // the Diary. All server-side in bulk, so huge histories land
            // fast — and a failure is SAID, never shrugged off.
            let detailItems = outcome.watched
                .filter { $0.imported.review != nil || !$0.imported.watchDates.isEmpty }
                .map { match in
                    SupabaseService.ImportDetailItem(
                        tmdb_id: match.movie.tmdbID,
                        media_kind: match.movie.mediaKind,
                        title: match.movie.title,
                        release_year: match.movie.releaseYear,
                        poster_path: match.movie.posterPath,
                        review: match.imported.review,
                        watched_on: match.imported.watchedOn,
                        watched_dates: match.imported.watchDates.sorted())
                }
            if !detailItems.isEmpty {
                progressText = "Saving your reviews and watch dates…"
                do {
                    try await SupabaseService.shared.importMovieDetails(detailItems)
                } catch {
                    // One quiet retry — the RPC is idempotent.
                    do {
                        try await SupabaseService.shared.importMovieDetails(detailItems)
                    } catch {
                        SupabaseService.logSwallowed("import_movie_details", error)
                        detailsImportFailed = true
                    }
                }
            }

            // Letterboxd watchlist → Cini watchlist.
            if importWatchlist {
                for match in outcome.watchlist
                where !store.isOnWatchlist(match.movie.tmdbID) && !store.isWatched(match.movie.tmdbID) {
                    await store.toggleWatchlist(movie: match.movie)
                }
            }

            // Letterboxd custom lists → Cini lists (same name reused).
            if !outcome.importedLists.isEmpty {
                let existing = (try? await SupabaseService.shared.myLists()) ?? []
                for list in outcome.importedLists {
                    var target = existing.first {
                        $0.name.localizedCaseInsensitiveCompare(list.name) == .orderedSame
                    }
                    if target == nil {
                        target = try? await SupabaseService.shared.createList(name: list.name)
                    }
                    guard let target else { continue }
                    for match in list.matches {
                        store.cache(match.movie)
                        try? await SupabaseService.shared.cacheMovie(match.movie)
                        try? await SupabaseService.shared.addToList(target.id, movieID: match.movie.tmdbID)
                    }
                }
                await store.refreshCustomLists()
            }

            result = outcome
            Haptics.success()
            ToastCenter.shared.show(successLine(for: outcome))
            withAnimation(.snappy) { phase = .summary }
        } catch {
            Haptics.error()
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Something went wrong reading that file."
            withAnimation(.snappy) { phase = .pick }
        }
    }

    /// "Imported 389 to rank · 57 saved · 2 lists" — the one-line receipt.
    private func successLine(for outcome: LetterboxdImporter.Result) -> String {
        var parts: [String] = []
        if pastedToWatchlist {
            parts.append("\(outcome.watched.count) saved to Want to Watch")
        } else {
            if !outcome.watched.isEmpty { parts.append("\(outcome.watched.count) to rank") }
            if importWatchlist && !outcome.watchlist.isEmpty {
                parts.append("\(outcome.watchlist.count) saved")
            }
        }
        let reviews = outcome.watched.filter { $0.imported.review != nil }.count
        if reviews > 0 && !detailsImportFailed {
            parts.append("\(reviews) review\(reviews == 1 ? "" : "s")")
        }
        if !outcome.importedLists.isEmpty {
            parts.append("\(outcome.importedLists.count) list\(outcome.importedLists.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Import complete" : "Imported: " + parts.joined(separator: " · ")
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
