import SwiftUI
import AuthenticationServices
import CryptoKit

/// Sign in: Apple first, email fallback. Username is claimed during
/// onboarding, so signup asks for the minimum — email + password.
struct AuthView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningUp = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var currentNonce: String?
    /// Set after signup, or when sign-in fails on an unconfirmed address —
    /// both surface the "Resend email" affordance.
    @State private var awaitingConfirmation = false
    @State private var resentJustNow = false
    @FocusState private var focusedField: Field?
    @Environment(\.colorScheme) private var colorScheme

    private enum Field { case email, password }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content
                    .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(
            Theme.background
                .contentShape(Rectangle())
                .onTapGesture { focusedField = nil }
                .ignoresSafeArea()
        )
        .swipeDismissesKeyboard()
    }

    private var content: some View {
        VStack(spacing: 22) {
            Spacer()

            Text("cini")
                .font(Theme.serif(64))
                .foregroundStyle(Theme.ink)
            Text("EVERY FILM · RANKED")
                .font(.system(size: 11, weight: .bold))
                .tracking(4)
                .foregroundStyle(Theme.gray)
            Text("Rank what you watch. No star ratings, ever.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)

            Spacer()

            SignInWithAppleButton(.continue) { request in
                let nonce = Self.randomNonce()
                currentNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                Task { await handleApple(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(Capsule())

            HStack {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("or with email").font(.caption).foregroundStyle(Theme.gray).fixedSize()
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            VStack(spacing: 10) {
                field("Email", text: $email, keyboard: .emailAddress)
                    // Keychain autofill needs the content types; without
                    // them sign-up means typing blind.
                    .textContentType(.emailAddress)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .focused($focusedField, equals: .email)
                SecureField("Password", text: $password)
                    // .newPassword makes iOS offer a strong password and
                    // save it on account creation.
                    .textContentType(isSigningUp ? .newPassword : .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await handleEmail() } }
                    .textFieldStyle(.plain)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                    .focused($focusedField, equals: .password)

                Button {
                    Task { await handleEmail() }
                } label: {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().tint(.white) }
                        Text(isSigningUp ? "Create account" : "Sign in")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Theme.velvet))
                }
                .buttonStyle(.plain)
                .disabled(isWorking || email.isEmpty || password.count < 6)
                .opacity(email.isEmpty || password.count < 6 ? 0.6 : 1)

                Button(isSigningUp ? "Have an account? Sign in" : "New here? Create an account") {
                    isSigningUp.toggle()
                    errorMessage = nil
                    infoMessage = nil
                }
                .font(.subheadline)
                .foregroundStyle(Theme.marquee)
            }

            Group {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed)
                } else if let infoMessage {
                    Text(infoMessage).font(.caption).foregroundStyle(Theme.scoreGreen)
                } else if isSigningUp {
                    Text("At least 6 characters for the password.")
                        .font(.caption).foregroundStyle(Theme.gray)
                }
                if awaitingConfirmation {
                    Button {
                        Task { await resendConfirmation() }
                    } label: {
                        Text(resentJustNow ? "Sent — check spam too" : "Didn't get it? Resend email")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(resentJustNow ? Theme.gray : Theme.marquee)
                    }
                    .disabled(resentJustNow)
                    .padding(.top, 2)
                }
            }
            .multilineTextAlignment(.center)

            Spacer()

            HStack(spacing: 14) {
                Link("Terms of Use",
                     destination: URL(string: "https://jtsilver123.github.io/cini/terms.html")!)
                Link("Privacy Policy",
                     destination: URL(string: "https://jtsilver123.github.io/cini/privacy.html")!)
            }
            .font(.caption2)
            .foregroundStyle(Theme.gray)
        }
        .padding(28)
    }

    private func field(_ placeholder: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
    }

    // MARK: - Actions

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        if case .failure(let error) = result {
            let code = (error as? ASAuthorizationError)?.code
            switch code {
            case .canceled:
                return   // user backed out — not an error
            case .unknown, .failed, .notHandled:
                // Almost always device/account-side: not signed into iCloud,
                // or the binary is missing the Sign in with Apple entitlement.
                errorMessage = "Apple sign-in isn't available right now — check you're signed into iCloud in Settings, or use email below."
            default:
                errorMessage = "Apple sign-in didn't complete — try again."
            }
            return
        }
        guard case .success(let auth) = result,
              let credential = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            errorMessage = "Apple sign-in didn't complete — try again."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await SupabaseService.shared.signInWithApple(idToken: token, nonce: nonce)
            // Apple shares the name only on the FIRST authorization — store
            // it now or it's gone forever.
            if let components = credential.fullName {
                let name = PersonNameComponentsFormatter().string(from: components)
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    try? await SupabaseService.shared.updateProfile(ProfileUpdate(display_name: name))
                }
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func handleEmail() async {
        email = email.trimmingCharacters(in: .whitespaces).lowercased()
        errorMessage = nil
        infoMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            if isSigningUp {
                try await SupabaseService.shared.signUp(
                    email: email, password: password,
                    username: "user_\(UUID().uuidString.prefix(8).lowercased())")
                infoMessage = "Check \(email) to confirm your account, then sign in."
                isSigningUp = false
                awaitingConfirmation = true
                resentJustNow = false
            } else {
                try await SupabaseService.shared.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = friendly(error)
            // The classic dead end: signed up, never confirmed, now locked
            // out. Give them a way to get a fresh link right here.
            if "\(error)".lowercased().contains("email not confirmed") {
                awaitingConfirmation = true
                resentJustNow = false
            }
        }
    }

    private func resendConfirmation() async {
        errorMessage = nil
        do {
            try await SupabaseService.shared.resendConfirmation(email: email)
            resentJustNow = true
            infoMessage = "New confirmation email sent to \(email)."
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Server errors, translated for humans.
    private func friendly(_ error: Error) -> String {
        let text = "\(error)".lowercased()
        if text.contains("invalid login credentials") { return "Wrong email or password." }
        if text.contains("validate email") || text.contains("invalid format") {
            return "That doesn't look like an email address — check for typos."
        }
        if text.contains("already registered") { return "That email already has an account — sign in instead." }
        if text.contains("email not confirmed") { return "Confirm your email first — check your inbox." }
        if text.contains("network") || text.contains("offline") || text.contains("timed out") {
            return "No connection — check your internet and try again."
        }
        if text.contains("at least 6") || text.contains("password") { return "Password needs at least 6 characters." }
        return "Something went wrong — try again."
    }

    // MARK: Apple nonce helpers

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
