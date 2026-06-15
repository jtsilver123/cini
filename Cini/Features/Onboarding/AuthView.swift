import SwiftUI

/// Beli-style auth: one thing per screen. Sign-in is a single screen (email
/// OR phone + password). Sign-up is email → password, then straight into
/// onboarding (email confirmation is off, so signup returns a live session).
struct AuthView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isSigningUp: Bool
    @State private var signupStep = 0   // 0 = email, 1 = password
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
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
            if signupStep == 0 {
                header("What's your email?", "We'll use it to keep your account safe.")
                authField("Email", text: $email, keyboard: .emailAddress)
                primaryButton("Continue", disabled: !email.contains("@")) {
                    focused = false
                    withAnimation { signupStep = 1 }
                }
                Button("Have an account? Sign in") { switchMode(toSignUp: false) }
                    .font(.subheadline).foregroundStyle(Theme.marquee)
            } else {
                header("Create a password", "At least 6 characters.")
                authField("Password", text: $password, secure: true)
                primaryButton("Create account", loading: isWorking,
                              disabled: password.count < 6) {
                    Task { await signUp() }
                }
                messages
            }
            Spacer(minLength: 20)
            legal
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
        password = ""
    }

    private func signIn() async {
        let id = email.trimmingCharacters(in: .whitespaces).lowercased()
        errorMessage = nil
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
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await SupabaseService.shared.signUp(
                email: email, password: password,
                username: "user_\(UUID().uuidString.prefix(8).lowercased())")
            // Email confirmation is off, so signUp returns a live session — the
            // auth state flips and onboarding takes over automatically.
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
        if text.contains("network") || text.contains("offline") || text.contains("timed out") {
            return "No connection — check your internet and try again."
        }
        if text.contains("at least 6") || text.contains("password") { return "Password needs at least 6 characters." }
        return "Something went wrong — try again."
    }
}
