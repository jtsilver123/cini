import SwiftUI

/// Beli-style auth: one thing per screen. Sign-in is a single screen (email
/// OR phone + password). Sign-up is a short sequence — email → password →
/// "check your email" — then onboarding collects the rest (phone first).
struct AuthView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isSigningUp: Bool
    @State private var signupStep = 0   // 0 = email, 1 = password, 2 = confirm
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var awaitingConfirmation = false
    @State private var resentJustNow = false
    @FocusState private var focused: Bool

    init(startInSignUp: Bool = false) {
        _isSigningUp = State(initialValue: startInSignUp)
    }

    var body: some View {
        ZStack {
            Theme.background
                .contentShape(Rectangle())
                .onTapGesture { focused = false }
                .ignoresSafeArea()
            ScrollView {
                (isSigningUp ? AnyView(signUpFlow) : AnyView(signInScreen))
                    .padding(.horizontal, 28)
                    .padding(.top, 60)
                    .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .topLeading) {
            Button {
                if isSigningUp && signupStep > 0 { withAnimation { signupStep -= 1 } }
                else { dismiss() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).padding(12)
            }
            .accessibilityLabel("Back")
        }
        .swipeDismissesKeyboard()
    }

    // MARK: Sign in

    private var signInScreen: some View {
        VStack(spacing: 18) {
            header("Welcome back", "Sign in to pick up your rankings.")
            authField("Email or phone", text: $email, keyboard: .emailAddress)
            authField("Password", text: $password, secure: true)
            primaryButton("Sign in", loading: isWorking,
                          disabled: email.isEmpty || password.count < 6) {
                Task { await signIn() }
            }
            messages
            Button("New here? Create an account") { switchMode(toSignUp: true) }
                .font(.subheadline).foregroundStyle(Theme.marquee)
            Spacer(minLength: 20)
            legal
        }
    }

    // MARK: Sign up sequence

    @ViewBuilder private var signUpFlow: some View {
        VStack(spacing: 18) {
            switch signupStep {
            case 0:
                header("What's your email?", "We'll send a link to confirm it.")
                authField("Email", text: $email, keyboard: .emailAddress)
                primaryButton("Continue", disabled: !email.contains("@")) {
                    focused = false
                    withAnimation { signupStep = 1 }
                }
                Button("Have an account? Sign in") { switchMode(toSignUp: false) }
                    .font(.subheadline).foregroundStyle(Theme.marquee)
            case 1:
                header("Create a password", "At least 6 characters.")
                authField("Password", text: $password, secure: true)
                primaryButton("Create account", loading: isWorking,
                              disabled: password.count < 6) {
                    Task { await signUp() }
                }
                messages
            default:
                confirmScreen
            }
            Spacer(minLength: 20)
            legal
        }
    }

    private var confirmScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge").font(.system(size: 54)).foregroundStyle(Theme.marquee)
            Text("Check your email").font(Theme.serif(30)).foregroundStyle(Theme.ink)
            Text("We sent a confirmation link to \(email). Tap it, then come back and sign in.")
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 16)
            Button(resentJustNow ? "Sent — check spam too" : "Resend email") {
                Task { await resend() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(resentJustNow ? Theme.gray : Theme.marquee)
            .disabled(resentJustNow)
            primaryButton("Back to sign in", disabled: false) { switchMode(toSignUp: false) }
            messages
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.serif(32)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 6)
    }

    private func authField(_ placeholder: String, text: Binding<String>,
                           secure: Bool = false, keyboard: UIKeyboardType = .default) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
                    .textContentType(isSigningUp ? .newPassword : .password)
            } else {
                TextField(placeholder, text: text)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
            }
        }
        .focused($focused)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
    }

    private func primaryButton(_ title: String, loading: Bool = false,
                               disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Capsule().fill(Theme.velvet))
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
        .opacity(disabled ? 0.6 : 1)
    }

    @ViewBuilder private var messages: some View {
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed).multilineTextAlignment(.center)
        } else if let infoMessage {
            Text(infoMessage).font(.caption).foregroundStyle(Theme.scoreGreen).multilineTextAlignment(.center)
        }
    }

    private var legal: some View {
        HStack(spacing: 14) {
            Link("Terms of Use", destination: URL(string: "https://jtsilver123.github.io/cini/terms.html")!)
            Link("Privacy Policy", destination: URL(string: "https://jtsilver123.github.io/cini/privacy.html")!)
        }
        .font(.caption2).foregroundStyle(Theme.gray)
    }

    // MARK: Actions

    private func switchMode(toSignUp: Bool) {
        isSigningUp = toSignUp
        signupStep = 0
        errorMessage = nil
        infoMessage = nil
        awaitingConfirmation = false
        password = ""
    }

    private func signIn() async {
        let id = email.trimmingCharacters(in: .whitespaces).lowercased()
        errorMessage = nil; infoMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            if id.contains("@") {
                try await SupabaseService.shared.signIn(email: id, password: password)
            } else {
                try await SupabaseService.shared.signInWithPhone(phone: id, password: password)
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func signUp() async {
        email = email.trimmingCharacters(in: .whitespaces).lowercased()
        errorMessage = nil; infoMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await SupabaseService.shared.signUp(
                email: email, password: password,
                username: "user_\(UUID().uuidString.prefix(8).lowercased())")
            awaitingConfirmation = true
            resentJustNow = false
            withAnimation { signupStep = 2 }
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func resend() async {
        errorMessage = nil
        do {
            try await SupabaseService.shared.resendConfirmation(email: email)
            resentJustNow = true
            infoMessage = "New confirmation email sent to \(email)."
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        let text = "\(error)".lowercased()
        if text.contains("invalid login credentials") { return "Wrong email or password." }
        if text.contains("invalid_credentials") || text.contains("401") {
            return "Wrong email/phone or password."
        }
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
}
