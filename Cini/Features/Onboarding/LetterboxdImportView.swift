import SwiftUI
import UniformTypeIdentifiers

/// Letterboxd / IMDb import. Accepts the actual Letterboxd export ZIP
/// (or any single CSV), matches every title against TMDB with live
/// progress, auto-imports the Letterboxd watchlist, and seeds the
/// persistent "Movies you may have seen" ranking queue — favorites first.
struct LetterboxdImportView: View {
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .pick
    @State private var importWatchlist = true
    @State private var result: LetterboxdImporter.Result?
    @State private var transferCode: String?
    @State private var transferTask: Task<Void, Never>?
    @State private var progressText = ""
    @State private var progressFraction: Double = 0
    @State private var errorMessage: String?
    @State private var showPicker = false
    @State private var showPaste = false
    @State private var pastedText = ""

    enum Phase {
        case pick, working, summary
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
            .onDisappear { transferTask?.cancel() }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase != .working {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(phase == .summary ? "Done" : "Cancel") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showPaste) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Copy your movie list in Notes, then paste it here — one title per line. Bullets, numbering, and years like \"Dune (2021)\" all work.")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                        TextEditor(text: $pastedText)
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                        PillButton(title: "Import list") {
                            showPaste = false
                            Task { await runPastedImport() }
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Paste from Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showPaste = false }
                        }
                    }
                }
                .presentationDetents([.large])
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.zip, .commaSeparatedText, .plainText]
            ) { pickResult in
                if case .success(let url) = pickResult {
                    Task { await runImport(from: url) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .working)
    }

    // MARK: Step 1 — pick the file

    private var pickStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.marquee)
                    .padding(.top, 28)
                Text("Bring your history")
                    .font(Theme.serif(30))
                Text("Takes about 1 minute. Letterboxd's export only works from a computer — grab a code here, do the export there, and it beams straight to your phone.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                desktopCard

                Toggle(isOn: $importWatchlist) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also import my watchlist").font(.subheadline.weight(.semibold))
                        Text("Letterboxd watchlist → your Want to Watch list")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                .tint(Theme.marquee)
                .padding(.horizontal, 4)

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
                        summaryRow(icon: "film.stack", count: result.watched.count,
                                   label: "films queued to rank",
                                   detail: "Find them under Search → \"Movies you may have seen\" — your favorites are first.")
                        Divider()
                        summaryRow(icon: "bookmark.fill", count: importWatchlist ? result.watchlist.count : 0,
                                   label: "added to your watchlist",
                                   detail: importWatchlist ? nil : "Watchlist import was off.")
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

                PillButton(title: "Start ranking", systemImage: "arrow.right") {
                    dismiss()
                }
            }
            .padding(20)
        }
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
            ImportQueue.shared.seed(with: outcome.watched, store: store)
            result = outcome
            withAnimation(.snappy) { phase = .summary }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't read that list."
            withAnimation(.snappy) { phase = .pick }
        }
    }

    // MARK: Desktop transfer - export on a computer, beam it here

    private var importPageURL: String { "https://jtsilver123.github.io/cini/import/" }

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
                    Text("On your computer, open the page below, enter this code, and drop in your export - it lands here automatically.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                    HStack {
                        Spacer()
                        Text(transferCode)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .tracking(6)
                            .foregroundStyle(Theme.marquee)
                        Spacer()
                    }
                    Text(importPageURL.replacingOccurrences(of: "https://", with: ""))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your upload… code works for 30 minutes")
                            .font(.caption2)
                            .foregroundStyle(Theme.gray)
                    }
                    Link(destination: emailMyselfURL(code: transferCode)) {
                        HStack(spacing: 6) {
                            Image(systemName: "envelope")
                            Text("Email me the link").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.marquee)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label { Text("Tap below for a 6-letter code") } icon: {
                            Text("1").bold().foregroundStyle(Theme.marquee)
                        }
                        Label { Text("On your computer: export at **letterboxd.com/settings/data**") } icon: {
                            Text("2").bold().foregroundStyle(Theme.marquee)
                        }
                        Label { Text("Drop the .zip at our import page — it lands here by itself") } icon: {
                            Text("3").bold().foregroundStyle(Theme.marquee)
                        }
                    }
                    .font(.subheadline)
                    PillButton(title: "Get a transfer code", systemImage: "laptopcomputer.and.iphone") {
                        Task { await startDesktopTransfer() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emailMyselfURL(code: String) -> URL {
        let body = [
            "Do this on your computer:",
            "",
            "1. Go to https://letterboxd.com/settings/data and click \"Export your data\"",
            "2. Open \(importPageURL)?code=\(code)",
            "3. Drop the .zip in - it appears in Cini on your phone automatically",
            "",
            "The code (\(code)) works for 30 minutes; grab a fresh one in the app if it expires.",
        ].joined(separator: "\n")
        var components = URLComponents(string: "mailto:")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Import your Letterboxd into Cini"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? URL(string: "mailto:")!
    }

    private func startDesktopTransfer() async {
        guard let code = try? await SupabaseService.shared.createImportCode() else {
            errorMessage = "Couldn't start a transfer - check your connection."
            return
        }
        transferCode = code
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
        }
    }

    private func importFromStorage(path: String) async {
        do {
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

            // Letterboxd watchlist → Cini watchlist.
            if importWatchlist {
                for match in outcome.watchlist
                where !store.isOnWatchlist(match.movie.tmdbID) && !store.isWatched(match.movie.tmdbID) {
                    await store.toggleWatchlist(movie: match.movie)
                }
            }

            result = outcome
            withAnimation(.snappy) { phase = .summary }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Something went wrong reading that file."
            withAnimation(.snappy) { phase = .pick }
        }
    }
}
