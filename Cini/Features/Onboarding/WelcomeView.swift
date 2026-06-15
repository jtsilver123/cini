import SwiftUI

/// The front door (Beli-style): a value-prop carousel shown BEFORE we ask for
/// anything, then "Get started" / "Sign in". Branding is the cinema palette —
/// marquee gold on the house-lights-down background. Each slide carries a small
/// in-app mockup so people see the product, not just words.
struct WelcomeView: View {
    @State private var page = 0
    @State private var showAuth = false
    @State private var startInSignUp = true

    private let slideCount = 3

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // Warm marquee glow up top.
            RadialGradient(colors: [Theme.marquee.opacity(0.16), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    slide(
                        mock: { CompareMock() },
                        title: "No star ratings. Ever.",
                        subtitle: "Answer one question — which did you like more? — and Cini slots every title exactly where it belongs."
                    ).tag(0)
                    slide(
                        mock: { RankedListMock() },
                        title: "Your taste, perfectly ordered",
                        subtitle: "A few quick taps build your ranked list of everything you've watched, with scores that come from your own taste."
                    ).tag(1)
                    slide(
                        mock: { FriendsMock() },
                        title: "Better with friends",
                        subtitle: "See what friends thought before you commit a night to it, get recs that match your taste, and race the leaderboard."
                    ).tag(2)
                }
                // Default UIPageControl dots wash out in light mode, so we draw
                // our own from Theme tokens instead.
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.snappy, value: page)

                pageDots
                    .padding(.bottom, 18)

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
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .fullScreenCover(isPresented: $showAuth) {
            AuthView(startInSignUp: startInSignUp)
        }
    }

    /// Custom page indicator: a gold "lozenge" for the current slide, soft gray
    /// dots for the rest. Both tokens are adaptive, so contrast holds in the
    /// cream matinee and the dark screening room alike.
    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<slideCount, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Theme.marquee : Theme.gray.opacity(0.4))
                    .frame(width: i == page ? 22 : 7, height: 7)
                    .animation(.snappy, value: page)
            }
        }
    }

    private func slide<Mock: View>(@ViewBuilder mock: () -> Mock,
                                   title: String, subtitle: String) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            PhoneMockup { mock() }
            VStack(spacing: 10) {
                Text(title)
                    .font(Theme.serif(28))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }
            Spacer(minLength: 8)
        }
    }
}

// MARK: - Phone mockups (pure SwiftUI, adapt to light/dark via Theme)

/// A small device frame the slide mockups live in.
private struct PhoneMockup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(14)
            .frame(width: 224, height: 300, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow, radius: 22, y: 12)
    }
}

/// A poster stand-in: a two-tone gradient with the title, like the marketing site.
private struct MockPoster: View {
    let title: String
    let c1: Color
    let c2: Color
    var height: CGFloat = 116

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(height: height)
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
            }
    }
}

private func mockBadge(_ value: String, _ color: Color) -> some View {
    Text(value)
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color))
}

/// Slide 1 — the signature compare screen.
private struct CompareMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RANK YOUR WATCH")
                .font(.system(size: 9, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.gray)
            Text("Which did you\nlike more?")
                .font(Theme.serif(18))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                MockPoster(title: "Whiplash", c1: Color(red: 0.12, green: 0.43, blue: 0.42),
                           c2: Color(red: 0.05, green: 0.16, blue: 0.23))
                Text("vs").font(.caption.weight(.heavy)).foregroundStyle(Theme.gray)
                MockPoster(title: "Interstellar", c1: Theme.velvet,
                           c2: Color(red: 0.91, green: 0.71, blue: 0.30))
            }
            HStack(spacing: 6) {
                Circle().fill(Theme.sentimentLoved).frame(width: 10, height: 10)
                Circle().fill(Theme.sentimentFine).frame(width: 10, height: 10)
                Circle().fill(Theme.sentimentDisliked).frame(width: 10, height: 10)
                Spacer()
            }
            .padding(.top, 2)
        }
    }
}

/// Slide 2 — the ranked list with scores.
private struct RankedListMock: View {
    private let rows: [(String, String, String, Color)] = [
        ("1", "Parasite", "9.4", Theme.scoreGreen),
        ("2", "Whiplash", "8.8", Theme.scoreGreen),
        ("3", "Interstellar", "7.1", Theme.scoreAmber),
        ("4", "Dune", "6.5", Theme.scoreAmber),
    ]
    private let swatches: [(Color, Color)] = [
        (Color(red: 0.23, green: 0.16, blue: 0.35), Theme.velvet),
        (Color(red: 0.12, green: 0.43, blue: 0.42), Color(red: 0.05, green: 0.16, blue: 0.23)),
        (Theme.velvet, Color(red: 0.91, green: 0.71, blue: 0.30)),
        (Color(red: 0.30, green: 0.25, blue: 0.18), Color(red: 0.55, green: 0.42, blue: 0.20)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR RANKING")
                .font(.system(size: 9, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.gray)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 9) {
                    Text(row.0).font(.caption.weight(.bold)).foregroundStyle(Theme.gray)
                        .frame(width: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [swatches[i].0, swatches[i].1],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 26, height: 36)
                    Text(row.1).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    mockBadge(row.2, row.3)
                }
            }
        }
    }
}

/// Slide 3 — friends' activity in the feed.
private struct FriendsMock: View {
    private let rows: [(String, Color, String, String, String, Color)] = [
        ("MK", Color(red: 0.55, green: 0.35, blue: 0.7), "Maya", "ranked Dune", "8.7", Theme.scoreGreen),
        ("JR", Theme.velvet, "Jordan", "loved Sinners", "9.2", Theme.scoreGreen),
        ("AL", Color(red: 0.20, green: 0.5, blue: 0.45), "Alex", "rated Wicked", "6.4", Theme.scoreAmber),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FRIENDS' TAKES")
                .font(.system(size: 9, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.gray)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Circle().fill(row.1).frame(width: 30, height: 30)
                        .overlay(Text(row.0).font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.2).font(.caption.weight(.bold)).foregroundStyle(Theme.ink)
                        Text(row.3).font(.system(size: 10)).foregroundStyle(Theme.gray).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    mockBadge(row.4, row.5)
                }
            }
        }
    }
}
