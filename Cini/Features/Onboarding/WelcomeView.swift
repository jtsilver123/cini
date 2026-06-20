import SwiftUI

/// The front door: a cinematic wall of movie posters drifting behind the
/// wordmark + promise, with "Get started" / "Sign in". The wall scrolls on its
/// own and the user can drag to scrub it faster — it sets the movie-night tone
/// the instant the app opens.
struct WelcomeView: View {
    @State private var showAuth = false
    @State private var startInSignUp = true
    /// Poster paths for the wall — seeded with a curated set so the first frame
    /// is never empty, then refreshed with what's trending right now.
    @State private var posters: [String] = PosterWall.seed

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            // The drifting poster wall, full-bleed behind everything.
            PosterWall(posters: posters)
                .ignoresSafeArea()

            // Melt the wall into the background (Beli-style): posters fill the
            // top and dissolve into solid ground where the wordmark + buttons
            // live, with a light scrim up top for status-bar legibility.
            LinearGradient(stops: [
                .init(color: Theme.background.opacity(0.55), location: 0.0),
                .init(color: Theme.background.opacity(0.0), location: 0.12),
                .init(color: Theme.background.opacity(0.0), location: 0.34),
                .init(color: Theme.background.opacity(0.75), location: 0.52),
                .init(color: Theme.background, location: 0.66),
                .init(color: Theme.background, location: 1.0)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Warm marquee glow up top.
            RadialGradient(colors: [Theme.marquee.opacity(0.14), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Text("Cini")
                        .font(Theme.serif(46))
                        .foregroundStyle(Theme.ink)
                    Text("Rank everything you watch")
                        .font(Theme.serif(26))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Text("No star ratings. Just pick which you liked more, and Cini ranks everything by your taste.")
                        .font(.callout)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                }
                .shadow(color: Theme.background, radius: 12)

                VStack(spacing: 12) {
                    Button {
                        startInSignUp = true
                        showAuth = true
                    } label: {
                        Text("Get started")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(Capsule().fill(Theme.velvet))
                    }
                    .buttonStyle(.plain)

                    Button {
                        startInSignUp = false
                        showAuth = true
                    } label: {
                        Text("I already have an account")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)

                    // Legal disclosure (Beli-style), with tappable links.
                    Text("By continuing, you agree to our [Terms](https://trycini.com/terms.html) and acknowledge our [Privacy Policy](https://trycini.com/privacy.html).")
                        .font(.caption2)
                        .foregroundStyle(Theme.gray)
                        .tint(Theme.marquee)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
                .padding(.top, 28)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .task {
            // Refresh the wall with current posters (TMDB's client key works
            // pre-auth). Keep the seed if the fetch is thin or offline.
            if let trending = try? await TMDBService.shared.trending() {
                let paths = trending.compactMap(\.posterPath)
                if paths.count >= 9 { posters = paths }
            }
        }
        .fullScreenCover(isPresented: $showAuth) {
            AuthView(startInSignUp: startInSignUp)
        }
    }
}

// MARK: - Poster wall

/// Three columns of posters drifting vertically — the outer two down, the
/// middle one up — staggered so the rows brick-offset. It scrolls on its own
/// (a TimelineView clock drives the offset) and a drag scrubs it faster, with a
/// little momentum on release.
private struct PosterWall: View {
    let posters: [String]

    /// A curated first-frame set (real TMDB paths for well-known films) so the
    /// wall is populated instantly, before trending loads.
    static let seed: [String] = [
        "/7fn624j5lj3xTme2SgiLCeuedmO.jpg", // Whiplash
        "/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg", // Interstellar
        "/qJ2tW6WMUDux911r6m7haRef0WH.jpg", // The Dark Knight
        "/d5iIlFn5s0ImszYzBPb8JPIfbXD.jpg", // Pulp Fiction
        "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg", // Fight Club
        "/arw2vcBveWOVZr6pxd9XTd1TdQa.jpg", // Forrest Gump
        "/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg", // Inception
        "/7IiTTgloJzvGI1TAYymCfbfl3vT.jpg", // Parasite
        "/9O7gLzmreU0nGkIB6K3BsJbzvNv.jpg", // 1917
        "/39wmItIWsg5sZMyRUHLkWBcuVCM.jpg", // Spirited Away
        "/8UlWHLMpgZm9bx6QYh0NFoq67TZ.jpg", // The Matrix
        "/3bhkrj58Vtu7enYsRolD1fZdja1.jpg", // The Godfather
    ]

    private let tileW: CGFloat = 108
    private let tileH: CGFloat = 162
    private let spacing: CGFloat = 12

    @State private var begin = Date()
    @State private var scrub: CGFloat = 0      // user-added offset (persists)
    @State private var lastDrag: CGFloat = 0   // last drag translation, for deltas
    @State private var momentum: Task<Void, Never>?   // post-release inertia glide

    /// Deal posters round-robin into three columns; fall back to the seed.
    /// Each column is padded to enough tiles that its looped height always
    /// exceeds the tallest iPhone — otherwise the wrap happens ON screen and you
    /// see tiles teleport. ~9 tiles ≈ 1560pt, taller than any device.
    private var columns: [[String]] {
        let source = posters.isEmpty ? Self.seed : posters
        var cols: [[String]] = [[], [], []]
        for (i, p) in source.enumerated() { cols[i % 3].append(p) }
        return cols.map { col in
            guard !col.isEmpty else { return col }
            var out = col
            while out.count < 9 { out += col }
            return out
        }
    }

    var body: some View {
        let cols = columns   // compute once per layout, not every frame
        return TimelineView(.animation) { ctx in
            let t = CGFloat(ctx.date.timeIntervalSince(begin))
            HStack(spacing: spacing) {
                ForEach(Array(cols.enumerated()), id: \.offset) { idx, paths in
                    let dir: CGFloat = idx == 1 ? -1 : 1          // middle drifts up
                    let speed: CGFloat = 16 + CGFloat(idx) * 3    // gentle parallax
                    let phase = CGFloat(idx) * (tileH + spacing) * 0.5   // brick offset
                    PosterColumn(paths: paths, tileW: tileW, tileH: tileH, spacing: spacing,
                                 offset: t * speed * dir + scrub + phase)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(0.9)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    momentum?.cancel()   // a new touch stops any glide
                    // Track the finger incrementally so `scrub` always equals the
                    // exact release point — no jump when the gesture ends.
                    scrub += value.translation.height - lastDrag
                    lastDrag = value.translation.height
                }
                .onEnded { value in
                    lastDrag = 0
                    // Inertia: glide the remaining predicted distance out by
                    // stepping `scrub` each frame (NOT withAnimation — animating
                    // scrub would tween every poster's wrapped offset and fling
                    // the ones crossing the loop seam across the screen).
                    let total = value.predictedEndTranslation.height - value.translation.height
                    momentum?.cancel()
                    momentum = Task { @MainActor in
                        var remaining = total
                        while abs(remaining) > 0.5 && !Task.isCancelled {
                            let step = remaining * 0.12   // decelerating glide
                            scrub += step
                            remaining -= step
                            try? await Task.sleep(for: .milliseconds(16))
                        }
                    }
                }
        )
    }
}

/// One column: each poster is absolutely positioned at a wrapped Y so the
/// column loops forever for any offset (auto + drag).
private struct PosterColumn: View {
    let paths: [String]
    let tileW: CGFloat
    let tileH: CGFloat
    let spacing: CGFloat
    let offset: CGFloat

    var body: some View {
        let stride = tileH + spacing
        let total = stride * CGFloat(paths.count)
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ForEach(paths.indices, id: \.self) { i in
                    WallPoster(path: paths[i], width: tileW, height: tileH)
                        .offset(y: wrapped(CGFloat(i) * stride + offset,
                                           span: total, height: geo.size.height))
                }
            }
            .frame(width: tileW, alignment: .top)
        }
        .frame(width: tileW)
        .clipped()
    }

    /// Map an arbitrary y into the visible band [-stride, height], looping.
    private func wrapped(_ y: CGFloat, span: CGFloat, height: CGFloat) -> CGFloat {
        guard span > 0 else { return y }
        var r = y.truncatingRemainder(dividingBy: span)
        if r < 0 { r += span }
        // Place the band starting just above the top so tiles enter/exit cleanly.
        let buffer = tileH + spacing
        if r > height + buffer { r -= span }
        return r - buffer
    }
}

private struct WallPoster: View {
    let path: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        CachedAsyncImage(url: URL(string: "https://image.tmdb.org/t/p/w342\(path)")) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Theme.surface
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }
}
