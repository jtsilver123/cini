import SwiftUI

/// The front door (Luma-style): one calm, static welcome — a single product
/// mockup, the wordmark, a one-line promise, then "Get started" / "Sign in".
/// No carousel to swipe through; the value prop lands in one glance. Branding
/// is the cinema palette — marquee gold on the house-lights-down background.
struct WelcomeView: View {
    @State private var showAuth = false
    @State private var startInSignUp = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // Warm marquee glow up top.
            RadialGradient(colors: [Theme.marquee.opacity(0.16), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                PhoneMockup { CompareMock() }

                VStack(spacing: 12) {
                    Text("Cini")
                        .font(Theme.serif(44))
                        .foregroundStyle(Theme.ink)
                    Text("Rank everything you watch")
                        .font(Theme.serif(26))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Text("No star ratings — just pick which you liked more, and Cini orders your movies and shows by your own taste.")
                        .font(.callout)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                }
                .padding(.top, 28)

                Spacer(minLength: 12)

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

/// A real movie poster (from TMDB, the app's image source), with a two-tone
/// gradient + title as the offline/loading fallback.
private struct MockPoster: View {
    let title: String
    let path: String
    let c1: Color
    let c2: Color
    var height: CGFloat = 116

    var body: some View {
        CachedAsyncImage(url: URL(string: "https://image.tmdb.org/t/p/w342\(path)")) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .bottomLeading) {
                    Text(title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(8)
                }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The signature compare screen, shown in the welcome mockup.
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
                MockPoster(title: "Whiplash", path: "/7fn624j5lj3xTme2SgiLCeuedmO.jpg",
                           c1: Color(red: 0.12, green: 0.43, blue: 0.42),
                           c2: Color(red: 0.05, green: 0.16, blue: 0.23))
                Text("vs").font(.caption.weight(.heavy)).foregroundStyle(Theme.gray)
                MockPoster(title: "Interstellar", path: "/yQvGrMoipbRoddT0ZR8tPoR7NfX.jpg",
                           c1: Theme.velvet,
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
