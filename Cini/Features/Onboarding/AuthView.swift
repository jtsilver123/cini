import SwiftUI

/// Beli-style auth: one thing per screen. Sign-in is a single screen (email
/// OR phone + password). Sign-up is phone → email → password (phone first,
/// like Beli; the number is saved right after the account is created), then
/// straight into onboarding (email confirmation is off, so signup returns a
/// live session).
struct AuthView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isSigningUp: Bool
    @State private var signupStep = 0   // 0 = phone, 1 = email, 2 = password
    @State private var phone = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var revealPassword = false
    @FocusState private var focused: Bool

    init(startInSignUp: Bool = false) {
        _isSigningUp = State(initialValue: startInSignUp)
    }

    // Password policy lives in PasswordPolicy so this and the settings
    // "change password" screen share one rule set (shown live as a checklist).
    private var pwHasLength: Bool { PasswordPolicy.hasLength(password) }
    private var pwHasMix: Bool { PasswordPolicy.hasMix(password) }
    private var passwordValid: Bool { PasswordPolicy.isValid(password) }

    /// A light sanity check so "x@y" or "x@.com" don't pass the email step
    /// (the server validates for real; this just catches obvious typos).
    private var emailLooksValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard let at = e.firstIndex(of: "@") else { return false }
        let local = e[..<at], domain = e[e.index(after: at)...]
        return !local.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
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
                // Phone first, like Beli — it's the key for finding friends and
                // for "log in with phone". The account itself is still made with
                // email + password (saved on the next two screens).
                header("First, what's your number?",
                       "So friends from your contacts can find you. It's never shown on your profile.")
                phoneField
                if PhoneNumber.digits(phone).count >= 10 && !PhoneNumber.isValid(phone) {
                    Text("That doesn't look like a valid number — check for typos.")
                        .font(.caption).foregroundStyle(Theme.scoreRed)
                        .multilineTextAlignment(.center)
                }
                Text("By continuing you consent to occasional informational texts (like a friend's invite). Message & data rates may apply.")
                    .font(.caption2).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                primaryButton("Continue", disabled: !PhoneNumber.isValid(phone)) {
                    focused = false
                    withAnimation { signupStep = 1 }
                }
                Button("Have an account? Sign in") { switchMode(toSignUp: false) }
                    .font(.subheadline).foregroundStyle(Theme.marquee)
            case 1:
                header("What's your email?", "We'll use it to keep your account safe.")
                authField("Email", text: $email, keyboard: .emailAddress)
                primaryButton("Continue", disabled: !emailLooksValid) {
                    focused = false
                    withAnimation { signupStep = 2 }
                }
            default:
                header("Create a password", "Make it strong — this protects your account.")
                authField("Password", text: $password, secure: true)
                passwordRules
                primaryButton("Create account", loading: isWorking,
                              disabled: !passwordValid) {
                    Task { await signUp() }
                }
                messages
            }
            Spacer(minLength: 20)
            legal
        }
    }

    private var phoneField: some View {
        HStack(spacing: 6) {
            Text("+1").foregroundStyle(Theme.gray)
            TextField("Phone number", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focused)
                .onChange(of: phone) { _, new in
                    let formatted = PhoneNumber.formattedLive(new)
                    if formatted != phone { phone = formatted }
                }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
    }

    private var passwordRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            passwordRule(PasswordPolicy.lengthRule, pwHasLength)
            passwordRule(PasswordPolicy.mixRule, pwHasMix)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func passwordRule(_ text: String, _ met: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.footnote)
                .foregroundStyle(met ? Theme.scoreGreen : Theme.gray)
            Text(text)
                .font(.footnote)
                .foregroundStyle(met ? Theme.ink : Theme.gray)
        }
        .animation(.snappy(duration: 0.15), value: met)
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
        HStack(spacing: 8) {
            Group {
                if secure && !revealPassword {
                    SecureField(placeholder, text: text)
                        .textContentType(isSigningUp ? .newPassword : .password)
                } else if secure {
                    // Revealed: a plain field so the typed password is visible.
                    TextField(placeholder, text: text)
                        .textContentType(isSigningUp ? .newPassword : .password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField(placeholder, text: text)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                }
            }
            .focused($focused)
            if secure {
                Button { revealPassword.toggle() } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                        .foregroundStyle(Theme.gray)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
            }
        }
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
                guard PhoneNumber.isValid(id) else {
                    errorMessage = "Enter a valid email or phone number."
                    return
                }
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
            // auth state flips and onboarding takes over automatically. Save the
            // number we collected up front (phone-first signup); if it's already
            // on Cini, they can change it later in Settings.
            let saved = await SupabaseService.shared.setPhone(phone)
            if !saved {
                ToastCenter.shared.show("That number's already on Cini — you can update it in Settings.")
            }
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
        if text.contains("already") && text.contains("regist") {
            return "That email already has an account — sign in instead."
        }
        if text.contains("rate limit") || text.contains("for security purposes")
            || (text.contains("after") && text.contains("seconds")) {
            return "Too many tries just now — wait a minute, then try again."
        }
        if text.contains("network") || text.contains("offline") || text.contains("timed out") {
            return "No connection — check your internet and try again."
        }
        if text.contains("at least") || text.contains("password") {
            return "Password needs 8–20 characters with letters, numbers, and a special character."
        }
        return "Something went wrong — try again."
    }
}
