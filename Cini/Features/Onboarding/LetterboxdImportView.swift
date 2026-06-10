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
                Text("Import your Letterboxd export and Cini queues every film you've logged so you can rank them — favorites first. Your Letterboxd watchlist comes along too.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                HairlineCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text("In Letterboxd, open your **Profile**, tap the **gear icon** in the top left, scroll down to **Advanced settings**, and tap **Export your data** — the .zip saves to Files")
                        } icon: {
                            Text("1").bold().foregroundStyle(Theme.marquee)
                        }
                        Label {
                            Text("Come back here and **choose that file** (no need to unzip)")
                        } icon: {
                            Text("2").bold().foregroundStyle(Theme.marquee)
                        }
                        Label {
                            Text("IMDb ratings CSVs work too")
                        } icon: {
                            Text("3").bold().foregroundStyle(Theme.marquee)
                        }
                        Link(destination: URL(string: "https://letterboxd.com/settings/data/")!) {
                            HStack(spacing: 6) {
                                Image(systemName: "safari")
                                Text("Open Letterboxd export page")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Theme.marquee)
                        }
                        .padding(.top, 2)
                    }
                    .font(.subheadline)
                }

                Toggle(isOn: $importWatchlist) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also import my watchlist").font(.subheadline.weight(.semibold))
                        Text("Letterboxd watchlist → Cini watchlist, instantly")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                .tint(Theme.marquee)
                .padding(.horizontal, 4)

                PillButton(title: "Choose export file", systemImage: "folder") {
                    showPicker = true
                }

                Button {
                    showPaste = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                        Text("Or paste from Apple Notes").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.marquee)
                }
                .buttonStyle(.plain)

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
