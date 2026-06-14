import SwiftUI
import Combine
import RankingEngine

// The shareable "ticket" and the in-app result card are the SAME design —
// one `RankTicket` view, so what people screenshot matches what they just
// saw reveal. Cinema admit-one language, our brand, movies + TV.

/// The cinema-ticket result card. Generic over its poster / avatar / score
/// slots so the live in-app card (async images, animated score reveal) and
/// the rendered share image (pre-fetched UIImages, static score) share all
/// the chrome and never drift apart.
struct RankTicket<Poster: View, Avatar: View, Score: View>: View {
    let movie: Movie
    let rank: Int
    let name: String
    let handle: String
    var streakWeeks: Int = 0
    /// nil in-app (fills the card width); fixed for the rendered share image.
    var width: CGFloat? = nil
    @ViewBuilder var poster: () -> Poster
    @ViewBuilder var avatar: () -> Avatar
    @ViewBuilder var score: () -> Score

    var body: some View {
        VStack(spacing: 14) {
            // Whose take this is — leads the card so it reads as personal
            // and shareable, with the marquee opposite (Beli's wordmark spot).
            HStack(spacing: 9) {
                avatar()
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("@\(handle)")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("CINI")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(Theme.marquee)
            }

            poster()
                .frame(width: 150, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: Theme.cardShadow, radius: 10, y: 5)

            VStack(spacing: 3) {
                Text(movie.title)
                    .font(Theme.serif(24))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !movie.bylineText.isEmpty {
                    Text(movie.bylineText)
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .lineLimit(1)
                }
            }

            // The payoff — the big score in its circle.
            score()

            (Text("Ranked ") + Text("#\(rank)").foregroundStyle(Theme.gold))
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.ink)
            Text("on your Watched list")
                .font(.caption)
                .foregroundStyle(Theme.gray)

            if streakWeeks > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill").font(.caption2)
                    Text(streakWeeks == 1 ? "Streak started" : "\(streakWeeks)-week streak")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(Theme.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.gold.opacity(0.12)))
            }

            // Ticket perforation + admit-one footer.
            Line()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(Theme.hairline)
                .frame(height: 1)
                .padding(.top, 2)
            Text("ADMIT ONE · CINI")
                .font(.system(size: 10, weight: .bold))
                .tracking(3.5)
                .foregroundStyle(Theme.gray)
        }
        .padding(24)
        // In-app (width nil) fills the card; the rendered share image needs
        // a FIXED width so a short title can't shrink the ticket.
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width)
        .background(Theme.surface)
    }
}

/// The pre-reveal score circle — a spinning arc with the number flickering,
/// so it reads as "calculating your score" before the real `ScoreBadge`
/// springs in (no tap needed). Occupies the exact footprint of the badge so
/// the reveal swaps in place with no layout jump.
struct ScoreRevealPlaceholder: View {
    var size: CGFloat = 64
    @State private var spin = false
    @State private var flicker = 5.0
    private let tick = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.surface)
                .frame(width: size, height: size)
                .shadow(color: Theme.cardShadow, radius: 4, y: 2)
            // Indeterminate "computing" arc.
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(Theme.marquee, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Text(flicker, format: .number.precision(.fractionLength(1)))
                .font(.system(size: size * 0.32, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.gray.opacity(0.7))
        }
        .onAppear {
            withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
        .onReceive(tick) { _ in
            flicker = Double.random(in: 1...9.9)
        }
    }
}

/// The rendered share image: a fully-revealed ticket with pre-fetched
/// poster + avatar bitmaps (ImageRenderer can't wait on async images).
struct RankShareCard: View {
    let movie: Movie
    let scored: ScoredItem<Int>
    let poster: UIImage?
    var name: String = ""
    var handle: String = ""
    var avatar: UIImage?
    var streakWeeks: Int = 0

    var body: some View {
        RankTicket(
            movie: movie,
            rank: scored.rank,
            name: name.isEmpty ? "—" : name,
            handle: handle,
            streakWeeks: streakWeeks,
            width: 360,
            poster: {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.gray.opacity(0.18))
                        .overlay(Image(systemName: "film").font(.title).foregroundStyle(Theme.gray))
                }
            },
            avatar: {
                if let avatar {
                    Image(uiImage: avatar).resizable().scaledToFill()
                } else {
                    Circle().fill(Theme.marqueeSoft)
                        .overlay(
                            Text(initials)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.marquee)
                        )
                }
            },
            score: { ScoreBadge(score: scored.score, size: 64) }
        )
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
