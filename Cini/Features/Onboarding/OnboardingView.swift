import SwiftUI

/// First-run flow for a brand-new account:
///
///   1. Welcome — "Rank, don't rate" (the three circles, the one idea)
///   2. Claim your username (Apple sign-ins arrive as "user_a1b2c3d4")
///   3. Bring your history — Letterboxd ZIP / Apple Notes paste / skip
///   4. Rank your first movie — a poster grid of recognizable titles
///
/// Shown once (per device) when an authenticated user has zero rankings.
struct OnboardingView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    var onFinished: () -> Void

    @State private var step = 0
    @State private var username = ""
    @State private var displayName = ""
    @State private var usernameError: String?
    @State private var saving = false
    @State private var showImport = false
    @State private var starters: [Movie] = []
    @State private var logMovie: Movie?

    private var usernameValid: Bool {
        username.range(of: "^[a-z0-9_.]{3,30}$", options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            TabView(selection: $step) {
                welcomeStep.tag(0)
                usernameStep.tag(1)
                importStep.tag(2)
                firstRankStep.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: step)
        }
        .background(Theme.background)
        .sheet(isPresented: $showImport, onDismiss: { advance() }) {
            LetterboxdImportView()
        }
        .fullScreenCover(item: $logMovie, onDismiss: {
            if store.watchedCount > 0 { onFinished() }
        }) { movie in
            LogFlowView(movie: movie)
        }
        .task {
            username = session.profile?.username.hasPrefix("user_") == false
                ? (session.profile?.username ?? "") : ""
            displayName = session.profile?.displayName ?? ""
            starters = ((try? await TMDBService.shared.popular()) ?? [])
                .filter { $0.posterPath != nil }
                .prefix(12).map { $0 }
            for movie in starters { store.cache(movie) }
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.gold : Theme.fill)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .animation(.snappy, value: step)
    }

    private func advance() {
        withAnimation(.snappy) { step = min(step + 1, 3) }
    }

    // MARK: 1 — Welcome

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("cini")
                .font(Theme.serif(56))
                .foregroundStyle(Theme.ink)
            Text("EVERY FILM · RANKED")
                .font(.system(size: 11, weight: .bold))
                .tracking(4)
                .foregroundStyle(Theme.gray)

            VStack(spacing: 14) {
                Text("No star ratings. Ever.")
                    .font(.title3.weight(.bold))
                Text("You'll answer one question — **\"Which did you like more?\"** — and Cini builds your perfectly ordered list, with scores that come from your own taste.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 36)

            HStack(spacing: 22) {
                circle(Theme.sentimentLoved, "Liked it")
                circle(Theme.sentimentFine, "Fine")
                circle(Theme.sentimentDisliked, "Didn't")
            }
            .padding(.top, 6)

            Spacer()
            PillButton(title: "Get started") { advance() }
                .padding(.bottom, 36)
        }
    }

    private func circle(_ color: Color, _ label: String) -> some View {
        VStack(spacing: 8) {
            Circle().fill(color).frame(width: 52, height: 52)
            Text(label).font(.caption).foregroundStyle(Theme.gray)
        }
    }

    // MARK: 2 — Claim username

    private var usernameStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Claim your @")
                .font(Theme.serif(34))
            Text("This is how friends find and follow you.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)

            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(Theme.gray)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: username) { _, new in
                            username = new.lowercased()
                            usernameError = nil
                        }
                    if usernameValid {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.scoreGreen)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))

                TextField("Display name (optional)", text: $displayName)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
            }
            .padding(.horizontal, 28)

            Text(usernameError ?? "Lowercase letters, numbers, dots, underscores.")
                .font(.caption)
                .foregroundStyle(usernameError == nil ? Theme.gray : Theme.scoreRed)

            Spacer()
            PillButton(title: saving ? "Saving…" : "That's me") {
                Task { await saveUsername() }
            }
            .disabled(!usernameValid || saving)
            .padding(.bottom, 36)
        }
    }

    private func saveUsername() async {
        saving = true
        defer { saving = false }
        do {
            try await SupabaseService.shared.updateProfile(
                ProfileUpdate(username: username,
                              display_name: displayName.isEmpty ? nil : displayName))
            await session.loadProfile()
            advance()
        } catch {
            usernameError = "\(error)".lowercased().contains("duplicate")
                ? "That username is taken — try another."
                : "Couldn't save that username — try another."
        }
    }

    // MARK: 3 — Bring your history

    private var importStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40))
                .foregroundStyle(Theme.gold)
            Text("Bring your history")
                .font(Theme.serif(34))
            Text("Already track movies somewhere? Cini queues your whole history so you can rank it — favorites first.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            VStack(spacing: 12) {
                PillButton(title: "Import Letterboxd or IMDb", systemImage: "folder") {
                    showImport = true
                }
                PillButton(title: "Paste from Apple Notes", systemImage: "note.text", style: .outlined) {
                    showImport = true
                }
            }
            .padding(.top, 6)

            Spacer()
            Button("I'm starting fresh") { advance() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 36)
        }
    }

    // MARK: 4 — Rank your first movie

    private var firstRankStep: some View {
        VStack(spacing: 14) {
            Text("Rank your first movie")
                .font(Theme.serif(30))
                .padding(.top, 26)
            Text("Pick anything you've seen — your first one takes zero comparisons.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 14) {
                    ForEach(starters) { movie in
                        Button {
                            logMovie = movie
                        } label: {
                            VStack(spacing: 6) {
                                PosterView(url: movie.posterURL, width: 100)
                                Text(movie.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
            }

            Button("I'll explore first") { onFinished() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 24)
        }
    }
}
