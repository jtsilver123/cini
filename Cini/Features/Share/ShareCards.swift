import SwiftUI
import RankingEngine

// Shareable, on-brand cards built for Twitter/Instagram: a "My Top 5" ticket
// and a "Taste Match" ticket. Same cinema-ticket chrome as the rank result,
// rendered to a bitmap (ImageRenderer can't wait on async images, so posters
// and avatars are pre-fetched as UIImage first) and handed to a ShareLink.
// Every card carries the cini wordmark + site link so a post drives installs.

private let ciniSiteLine = "jtsilver123.github.io/cini"

// MARK: - Top 5 card

struct TopFiveShareCard: View {
    struct Row: Identifiable {
        let id = UUID()
        let poster: UIImage?
        let title: String
        let rank: Int
        let score: Double
    }

    let name: String
    let handle: String
    let avatar: UIImage?
    /// "MOVIES" or "SHOWS".
    let kindLabel: String
    let rows: [Row]
    var width: CGFloat = 360

    var body: some View {
        VStack(spacing: 14) {
            header
            Text("MY TOP \(rows.count) \(kindLabel)")
                .font(Theme.display(22))
                .foregroundStyle(Theme.marquee)
                .tracking(1)

            VStack(spacing: 10) {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Text("#\(row.rank)")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.gold)
                            .frame(width: 34, alignment: .leading)
                        posterThumb(row.poster)
                        Text(row.title)
                            .font(Theme.serif(17))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        ScoreBadge(score: row.score, size: 40)
                    }
                }
            }

            footer
        }
        .padding(24)
        .frame(width: width)
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(spacing: 9) {
            avatarThumb
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("@\(handle)").font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("CINI").font(.system(size: 12, weight: .heavy)).tracking(3).foregroundStyle(Theme.marquee)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Line()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(Theme.hairline)
                .frame(height: 1)
            HStack {
                Text("ADMIT ONE · CINI")
                    .font(.system(size: 10, weight: .bold)).tracking(3).foregroundStyle(Theme.gray)
                Spacer()
                Text(ciniSiteLine).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.gray)
            }
        }
    }

    private func posterThumb(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.gray.opacity(0.18))
                    .overlay(Image(systemName: "film").font(.caption).foregroundStyle(Theme.gray))
            }
        }
        .frame(width: 40, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var avatarThumb: some View {
        Group {
            if let avatar {
                Image(uiImage: avatar).resizable().scaledToFill()
            } else {
                Circle().fill(Theme.marqueeSoft)
                    .overlay(Text(initials(name)).font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.marquee))
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
    }
}

// MARK: - Taste match card

struct TasteMatchShareCard: View {
    let viewerName: String
    let viewerAvatar: UIImage?
    let memberName: String
    let memberHandle: String
    let memberAvatar: UIImage?
    let matchPct: Int
    var width: CGFloat = 360

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("TASTE MATCH").font(.system(size: 12, weight: .heavy)).tracking(3).foregroundStyle(Theme.gray)
                Spacer()
                Text("CINI").font(.system(size: 12, weight: .heavy)).tracking(3).foregroundStyle(Theme.marquee)
            }

            HStack(spacing: 18) {
                avatarBlock(viewerAvatar, viewerName)
                Text("×").font(Theme.serif(28)).foregroundStyle(Theme.gray)
                avatarBlock(memberAvatar, memberName)
            }
            .padding(.top, 4)

            Text("\(matchPct)%")
                .font(.system(size: 60, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.scoreColor(Double(matchPct) / 10))
            Text(verdict)
                .font(Theme.serif(20))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)

            Line()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(Theme.hairline)
                .frame(height: 1)
            HStack {
                Text("ADMIT ONE · CINI")
                    .font(.system(size: 10, weight: .bold)).tracking(3).foregroundStyle(Theme.gray)
                Spacer()
                Text(ciniSiteLine).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.gray)
            }
        }
        .padding(24)
        .frame(width: width)
        .background(Theme.surface)
    }

    private var verdict: String {
        switch matchPct {
        case 85...: return "Taste twins 🍿"
        case 70..<85: return "Watch together"
        case 50..<70: return "Some common ground"
        default: return "Opposites attract?"
        }
    }

    private func avatarBlock(_ image: UIImage?, _ who: String) -> some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Circle().fill(Theme.marqueeSoft)
                        .overlay(Text(initials(who)).font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.marquee))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            Text(who).font(.caption.weight(.bold)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        .frame(maxWidth: 110)
    }
}

private func initials(_ name: String) -> String {
    name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
}

// MARK: - Render-and-share sheets

/// Pre-fetches the bitmaps a card needs, renders it to an image, and offers a
/// one-tap ShareLink. Used by both card types via a closure that builds the
/// concrete card from the fetched images.
private func renderCard<V: View>(_ view: V) -> Image? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 3
    return renderer.uiImage.map(Image.init(uiImage:))
}

private func fetchImage(_ url: URL?) async -> UIImage? {
    guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
    return UIImage(data: data)
}

/// "Share my Top 5" — switch between Movies and Shows, share the rendered card.
struct TopFiveShareSheet: View {
    struct Entry { let movie: Movie; let rank: Int; let score: Double }

    let name: String
    let handle: String
    let avatarURL: URL?
    let movieEntries: [Entry]
    let showEntries: [Entry]

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "movie"
    @State private var shareImage: Image?
    @State private var avatar: UIImage?
    @State private var rendering = true

    private var entries: [Entry] { kind == "tv" ? showEntries : movieEntries }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if !movieEntries.isEmpty && !showEntries.isEmpty {
                    Picker("Kind", selection: $kind) {
                        Text("Movies").tag("movie")
                        Text("Shows").tag("tv")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                if let shareImage {
                    shareImage
                        .resizable().scaledToFit()
                        .frame(maxHeight: 460)
                        .shadow(color: Theme.cardShadow, radius: 12, y: 6)
                    ShareLink(item: shareImage,
                              preview: SharePreview("My Top \(entries.count) on Cini", image: shareImage)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Capsule().fill(Theme.velvet))
                    }
                    .padding(.horizontal)
                } else {
                    Spacer(); ProgressView(); Spacer()
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .background(Theme.background)
            .navigationTitle("Share your Top 5")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task(id: kind) { await render() }
        }
    }

    @MainActor
    private func render() async {
        rendering = true
        shareImage = nil
        if avatar == nil { avatar = await fetchImage(avatarURL) }
        var rows: [TopFiveShareCard.Row] = []
        for entry in entries.prefix(5) {
            let poster = await fetchImage(entry.movie.posterURL)
            rows.append(.init(poster: poster, title: entry.movie.title, rank: entry.rank, score: entry.score))
        }
        let card = TopFiveShareCard(
            name: name.isEmpty ? "—" : name, handle: handle, avatar: avatar,
            kindLabel: kind == "tv" ? "SHOWS" : "MOVIES", rows: rows)
        shareImage = renderCard(card)
        rendering = false
    }
}

/// "Share match" — the taste-match card between the viewer and a member.
struct TasteMatchShareSheet: View {
    let viewerName: String
    let viewerAvatarURL: URL?
    let memberName: String
    let memberHandle: String
    let memberAvatarURL: URL?
    let matchPct: Int

    @Environment(\.dismiss) private var dismiss
    @State private var shareImage: Image?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let shareImage {
                    shareImage
                        .resizable().scaledToFit()
                        .frame(maxHeight: 460)
                        .shadow(color: Theme.cardShadow, radius: 12, y: 6)
                    ShareLink(item: shareImage,
                              preview: SharePreview("Our taste match on Cini", image: shareImage)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Capsule().fill(Theme.velvet))
                    }
                    .padding(.horizontal)
                } else {
                    Spacer(); ProgressView(); Spacer()
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .background(Theme.background)
            .navigationTitle("Share your match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await render() }
        }
    }

    @MainActor
    private func render() async {
        let viewerAvatar = await fetchImage(viewerAvatarURL)
        let memberAvatar = await fetchImage(memberAvatarURL)
        let card = TasteMatchShareCard(
            viewerName: viewerName, viewerAvatar: viewerAvatar,
            memberName: memberName, memberHandle: memberHandle, memberAvatar: memberAvatar,
            matchPct: matchPct)
        shareImage = renderCard(card)
    }
}
