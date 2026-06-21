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
    @State private var country = CountryCode.usDefault
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var showForgot = false
    @State private var resetEmail = ""
    @State private var errorMessage: String?
    @State private var revealPassword = false
    @FocusState private var focused: Bool

    init(startInSignUp: Bool = false) {
        _isSigningUp = State(initialValue: startInSignUp)
    }

    // Password policy lives in PasswordPolicy so this and the settings
    // "change password" screen share one rule set (shown live as a checklist).
    private var pwHasLength: Bool { PasswordPolicy.hasLength(password) }
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
                    // Keep the auth form a comfortable column on iPad.
                    .nativeContentWidth(480)
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
            authField("Email, phone, or username", text: $email, keyboard: .emailAddress)
            authField("Password", text: $password, secure: true)
            primaryButton("Sign in", loading: isWorking,
                          disabled: email.isEmpty || password.isEmpty) {
                Task { await signIn() }
            }
            Button("Forgot password?") {
                // Prefill with the typed value if it looks like an email.
                resetEmail = email.contains("@") ? email : ""
                showForgot = true
            }
            .font(.subheadline).foregroundStyle(Theme.gray)
            messages
            Button("New to Cini? Create an account") { switchMode(toSignUp: true) }
                .font(.subheadline).foregroundStyle(Theme.marquee)
            Spacer(minLength: 20)
            legal
        }
        .alert("Reset password", isPresented: $showForgot) {
            TextField("Email", text: $resetEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            Button("Send link") {
                let target = resetEmail.trimmingCharacters(in: .whitespaces)
                guard target.contains("@") else {
                    ToastCenter.shared.show("Enter the email on your account.")
                    return
                }
                Task {
                    _ = await SupabaseService.shared.sendPasswordReset(email: target)
                    ToastCenter.shared.show("Check your email for a reset link 🎬")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll email you a link to set a new password.")
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
                if PhoneNumber.digits(phone).count >= 10 && !PhoneNumber.isValid(phone, dial: country.dial) {
                    Text("That doesn't look like a valid number — check for typos.")
                        .font(.caption).foregroundStyle(Theme.scoreRed)
                        .multilineTextAlignment(.center)
                }
                messages
                primaryButton("Continue", loading: isWorking,
                              disabled: !PhoneNumber.isValid(phone, dial: country.dial)) {
                    Task { await continueFromPhone() }
                }
                Button("Already have an account? Sign in") { switchMode(toSignUp: false) }
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
        HStack(spacing: 8) {
            // Country code picker — Beli lets you change it for non-US numbers.
            Menu {
                ForEach(CountryCode.common) { c in
                    Button("\(c.flag)  \(c.name)  \(c.dial)") {
                        country = c
                        reformatPhone()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(country.flag)
                    Text(country.dial).foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Theme.gray)
                }
            }
            Divider().frame(height: 22)
            TextField("Phone number", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focused)
                .onChange(of: phone) { _, new in
                    reformatPhone(new)
                    errorMessage = nil
                }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
    }

    /// US gets the "(555) 123-4567" formatting; other countries just keep the
    /// digits (no reliable single format), capped at a sane length.
    private func reformatPhone(_ new: String? = nil) {
        let raw = new ?? phone
        if country.dial == "+1" {
            let f = PhoneNumber.formattedLive(raw)
            if f != phone { phone = f }
        } else {
            let d = String(PhoneNumber.digits(raw).prefix(14))
            if d != phone { phone = d }
        }
    }

    /// Full E.164-ish number (country code + digits) sent to the server.
    /// Outside the +1 (NANP) plan, callers usually type the national trunk
    /// prefix (UK "07911…", etc.) — strip a single leading 0 so we don't build
    /// "+4407911…" instead of "+447911…".
    private var e164Phone: String {
        let digits = PhoneNumber.digits(phone)
        if country.dial != "+1", digits.hasPrefix("0") {
            return country.dial + String(digits.dropFirst())
        }
        return country.dial + digits
    }

    private var passwordRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            passwordRule(PasswordPolicy.lengthRule, pwHasLength)
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
            Link("Terms of Use", destination: URL(string: "https://trycini.com/terms.html")!)
            Link("Privacy Policy", destination: URL(string: "https://trycini.com/privacy.html")!)
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
            } else if isPhoneLike(id) {
                // Phone login matches on the last 10 digits server-side, so any
                // plausible number works — non-US users include their "+" code.
                guard PhoneNumber.digits(id).count >= 7 else {
                    errorMessage = "Enter a valid email, phone, or username."
                    return
                }
                try await SupabaseService.shared.signInWithPhone(phone: id, password: password)
            } else {
                // Anything with letters is treated as a username (a leading "@"
                // is fine — it's stripped server-side).
                try await SupabaseService.shared.signInWithUsername(username: id, password: password)
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// True when the identifier is only digits and phone separators (so it's a
    /// phone number, not a username). Usernames contain letters or underscores.
    private func isPhoneLike(_ s: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "+0123456789()-. ")
        return !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Phone step → email step, but first confirm the number isn't already on
    /// another account (each number must be unique, since it's a login key).
    private func continueFromPhone() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        if await SupabaseService.shared.phoneAvailable(e164Phone) {
            focused = false
            withAnimation { signupStep = 1 }
        } else {
            errorMessage = "That number's already on Cini — sign in instead."
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
            // number we collected up front (phone-first signup). Retry a couple
            // times so a transient blip right at signup doesn't silently drop it;
            // if it still won't save, stash it so loadProfile finishes the job
            // (otherwise a tear-down toast no one sees was the only signal, and
            // friends couldn't find the user by number).
            var saved = false
            for attempt in 0..<3 {
                saved = await SupabaseService.shared.setPhone(e164Phone)
                if saved { break }
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            }
            if !saved {
                UserDefaults.standard.set(e164Phone, forKey: "cini.pendingPhoneE164")
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
            return "Password needs at least 8 characters."
        }
        return "Something went wrong — try again."
    }
}
