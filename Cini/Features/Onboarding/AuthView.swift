import SwiftUI
import AuthenticationServices
import CryptoKit

/// Sign in with Apple (primary) + email fallback, on a poster-forward cover.
struct AuthView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var isSigningUp = false
    @State private var errorMessage: String?
    @State private var currentNonce: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Text("cini")
                .font(Theme.serif(64))
                .foregroundStyle(Theme.teal)
            Text("Rank every movie you've ever seen.")
                .font(.headline)
                .foregroundStyle(Theme.gray)

            Spacer()

            SignInWithAppleButton(.signIn) { request in
                let nonce = Self.randomNonce()
                currentNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                Task { await handleApple(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(Capsule())

            VStack(spacing: 10) {
                if isSigningUp {
                    field("Username", text: $username)
                }
                field("Email", text: $email)
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))

                PillButton(title: isSigningUp ? "Create account" : "Sign in") {
                    Task { await handleEmail() }
                }

                Button(isSigningUp ? "Have an account? Sign in" : "New here? Create an account") {
                    isSigningUp.toggle()
                }
                .font(.subheadline)
                .foregroundStyle(Theme.teal)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(28)
        .background(Theme.background)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        guard case .success(let auth) = result,
              let credential = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            errorMessage = "Sign in with Apple failed."
            return
        }
        do {
            try await SupabaseService.shared.signInWithApple(idToken: token, nonce: nonce)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleEmail() async {
        do {
            if isSigningUp {
                try await SupabaseService.shared.signUp(email: email, password: password, username: username)
            } else {
                try await SupabaseService.shared.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
