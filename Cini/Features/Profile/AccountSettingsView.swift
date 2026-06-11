import SwiftUI

/// Account settings (Beli's "Manage account"): change email, change
/// password, log out, delete account. Reached from Edit Profile and the
/// hamburger menu.
struct AccountSettingsView: View {
    @Environment(AppSession.self) private var session

    @State private var newEmail = ""
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Current email",
                               value: SupabaseService.shared.currentEmail ?? "—")
                TextField("New email", text: $newEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Send confirmation to new email") {
                    Task { await changeEmail() }
                }
                .disabled(!newEmail.contains("@"))
            } header: {
                Text("Email")
            } footer: {
                Text("The change applies once you tap the link we send to the new address.")
            }

            ChangePasswordSection()

            Section {
                NavigationLink {
                    NotificationPreferencesView()
                } label: {
                    Label("Notifications", systemImage: "bell.badge")
                }
            } footer: {
                Text("Choose which kinds of alerts Cini sends you.")
            }

            Section {
                Button("Log out", role: .destructive) {
                    Task { await session.signOut() }
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete my account")
                            Text("Permanently deletes your rankings, lists, and follows.")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                    }
                }
            }

            Section {
                Link(destination: URL(string: "https://jtsilver123.github.io/cini/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "mailto:jsilver@bettercampus.com?subject=Cini%20support")!) {
                    Label("Contact Support", systemImage: "envelope")
                }
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label("Movie data by TMDB", systemImage: "film")
                }
            } header: {
                Text("About")
            } footer: {
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(Theme.scoreGreen)
                    .listRowBackground(Color.clear)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background)
        .navigationTitle("Account Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your account forever?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("There's no undo — your rankings, watchlist, and followers are gone for good.")
        }
    }

    private func changeEmail() async {
        message = nil; errorMessage = nil
        do {
            try await SupabaseService.shared.updateEmail(
                newEmail.trimmingCharacters(in: .whitespaces).lowercased())
            message = "Confirmation sent to \(newEmail) — tap the link to finish."
            newEmail = ""
        } catch {
            errorMessage = "Couldn't start the email change — try again."
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await SupabaseService.shared.deleteAccount()
            // signOut inside deleteAccount flips auth state; AuthView appears.
        } catch {
            errorMessage = "Couldn't delete the account — try again or contact us."
        }
    }
}

/// Change password — its own section so the hamburger menu can present it
/// standalone too.
struct ChangePasswordSection: View {
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message: String?
    @State private var errorMessage: String?

    private var valid: Bool { newPassword.count >= 6 && newPassword == confirmPassword }

    var body: some View {
        Section {
            SecureField("New password", text: $newPassword)
            SecureField("Confirm new password", text: $confirmPassword)
            Button("Change password") {
                Task { await change() }
            }
            .disabled(!valid)
            if !newPassword.isEmpty && !valid {
                Text(newPassword.count < 6 ? "At least 6 characters." : "Passwords don't match.")
                    .font(.caption)
                    .foregroundStyle(Theme.scoreRed)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(Theme.scoreGreen)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed)
            }
        } header: {
            Text("Password")
        }
    }

    private func change() async {
        message = nil; errorMessage = nil
        do {
            try await SupabaseService.shared.updatePassword(newPassword)
            message = "Password updated."
            newPassword = ""; confirmPassword = ""
        } catch {
            errorMessage = "Couldn't change the password — try again."
        }
    }
}

/// Standalone wrapper so "Change Password" can open directly from a menu.
struct ChangePasswordView: View {
    var body: some View {
        Form { ChangePasswordSection() }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background)
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
    }
}
