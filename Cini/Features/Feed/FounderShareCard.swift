import SwiftUI

/// A one-time, dismissible note from the founder, shown on the feed: his photo,
/// a short message in his own handwriting, and a single ask — share Cini with
/// one person. The CTA opens the contacts invite flow. Genuine over salesy:
/// it's surfaced once (persisted), on the user's second app launch, so the ask
/// follows a return visit rather than greeting a stranger.
struct FounderShareCard: View {
    /// Open the contacts invite flow.
    var onShare: () -> Void
    /// Dismiss without sharing (respected — we don't ask again).
    var onDismiss: () -> Void

    /// Jake's account — the same id onboarding uses for "everyone follows Jake."
    private static let founderID = UUID(uuidString: "c8a4e18e-7b5b-405d-bb74-6e1e79702f60")!
    /// A built-in iOS handwriting face — no bundled font needed.
    private static let handwriting = "Bradley Hand"

    @State private var founder: Profile?

    var body: some View {
        ZStack {
            // Dim scrim — tapping outside the card dismisses, like any popup.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            card
                .padding(.horizontal, 28)
        }
        .task {
            if founder == nil {
                founder = try? await SupabaseService.shared.profile(id: Self.founderID).asProfile
            }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            AvatarView(url: founder?.avatarURL, size: 88,
                       name: founder?.displayName ?? "Jake Silver")
                .overlay(Circle().strokeBorder(Theme.marquee, lineWidth: 2).padding(-4))
                .padding(.top, 8)

            // The note, in his hand. Short, simple sentences so it's easy to read.
            Text("Hi, I'm Jake. I made Cini by myself. There's no big company, just me. Cini can only grow if you help. Will you ask one friend to download it? Just one. Thank you!")
                .font(.custom(Self.handwriting, size: 21, relativeTo: .body))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text("Jake 🎬")
                .font(.custom(Self.handwriting, size: 20, relativeTo: .body))
                .foregroundStyle(Theme.marquee)

            PillButton(title: "Invite one friend", systemImage: "square.and.arrow.up") {
                onShare()
            }
            .padding(.top, 4)

            Button("Maybe later") { onDismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 26, y: 12)
        .overlay(alignment: .topTrailing) {
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.gray)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }
}
