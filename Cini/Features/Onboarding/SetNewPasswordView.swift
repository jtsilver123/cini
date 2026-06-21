import SwiftUI

/// Shown after a password-recovery link (cini://reset) opens the app. By the
/// time we get here the recovery session is already established, so the user
/// just picks a new password — then they're signed in normally.
struct SetNewPasswordView: View {
    var onDone: () -> Void

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var reveal = false
    @State private var saving = false
    @State private var errorText: String?

    private var valid: Bool {
        PasswordPolicy.isValid(newPassword) && newPassword == confirmPassword
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.rotation")
                .font(.system(size: 44)).foregroundStyle(Theme.marquee)
            Text("Set a new password")
                .font(Theme.serif(30)).multilineTextAlignment(.center)
            Text("Choose a new password for your Cini account.")
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                passwordField("New password", text: $newPassword)
                passwordField("Confirm new password", text: $confirmPassword)
                ruleRow(PasswordPolicy.lengthRule, PasswordPolicy.hasLength(newPassword))
                if !confirmPassword.isEmpty && newPassword != confirmPassword {
                    ruleRow("Passwords match", false)
                }
            }
            .screenHPadding()
            .padding(.top, 4)

            PillButton(title: saving ? "Saving…" : "Save new password",
                       style: .filled, fill: true) {
                Task { await save() }
            }
            .screenHPadding()
            .disabled(!valid || saving)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(Theme.scoreRed)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    @ViewBuilder
    private func passwordField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Group {
                if reveal { TextField(placeholder, text: text) }
                else { SecureField(placeholder, text: text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(Theme.gray)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    }

    private func ruleRow(_ text: String, _ met: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? Theme.scoreGreen : Theme.gray)
            Text(text).foregroundStyle(met ? Theme.ink : Theme.gray)
            Spacer()
        }
        .font(.caption)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        errorText = nil
        do {
            try await SupabaseService.shared.updatePassword(newPassword)
            Haptics.success()
            ToastCenter.shared.show("Password updated — you're signed in 🎬")
            onDone()
        } catch {
            errorText = "Couldn't update the password — try again."
            saving = false
        }
    }
}
