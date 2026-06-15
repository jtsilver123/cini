import SwiftUI

/// "Manage account" (Beli-style): a clean list of tap-through rows — change
/// email / phone / password, preferences, data, then the red zone (log out,
/// delete). Each editor is its own focused screen so this list stays simple.
struct AccountSettingsView: View {
    @Environment(AppSession.self) private var session

    @State private var currentPhone = ""
    @State private var loaded = false
    @State private var showDeleteConfirm = false
    @State private var showLogoutConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @AppStorage("cini.appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section("Account") {
                navRow("Change email", systemImage: "envelope",
                       value: SupabaseService.shared.currentEmail) { ChangeEmailScreen() }
                navRow("Change phone number", systemImage: "phone",
                       value: currentPhone.isEmpty ? nil : currentPhone) {
                    ChangePhoneScreen(phone: currentPhone) { currentPhone = $0 }
                }
                navRow("Change password", systemImage: "lock") { ChangePasswordScreen() }
            }

            Section("Preferences") {
                NavigationLink {
                    NotificationPreferencesView()
                } label: { Label("Notifications", systemImage: "bell.badge") }
                NavigationLink {
                    TheaterAlertsScreen()
                } label: { Label("Theater alerts", systemImage: "popcorn") }
                Picker(selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Match device").tag("system")
                } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            }

            Section("Your data") {
                ExportRow()
            }

            Section("About") {
                Link(destination: URL(string: "https://jtsilver123.github.io/cini/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://jtsilver123.github.io/cini/terms.html")!) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
                Link(destination: URL(string: "mailto:jtsilver123@gmail.com?subject=Cini%20support")!) {
                    Label("Contact Support", systemImage: "envelope")
                }
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label("Movie data by TMDB", systemImage: "film")
                }
            }

            Section {
                Button("Log out", role: .destructive) { showLogoutConfirm = true }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Text(isDeleting ? "Deleting…" : "Delete my account")
                        if isDeleting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isDeleting)
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.scoreRed)
                } else {
                    Text("Deleting is permanent — your rankings, lists, and follows are gone for good.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Manage account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Log out of Cini?",
                            isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { Task { await session.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete your account forever?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("There's no undo — your rankings, Want to Watch, and followers are gone for good.")
        }
        .task {
            guard !loaded else { return }
            loaded = true
            currentPhone = await SupabaseService.shared.myPhone() ?? ""
        }
    }

    /// A tap-through row with an optional current value beneath the title.
    private func navRow<Destination: View>(_ title: String, systemImage: String,
                                           value: String? = nil,
                                           @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 24).foregroundStyle(Theme.marquee)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(Theme.ink)
                    if let value, !value.isEmpty {
                        Text(value).font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
                    }
                }
            }
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await SupabaseService.shared.deleteAccount()
        } catch {
            errorMessage = "Couldn't delete the account — try again or contact us."
        }
    }
}

// MARK: - Change email

private struct ChangeEmailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newEmail = ""
    @State private var message: String?
    @State private var errorMessage: String?

    private var valid: Bool {
        let t = newEmail.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        return t[t.index(after: at)...].contains(".")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current", value: SupabaseService.shared.currentEmail ?? "—")
                TextField("New email", text: $newEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("The change applies once you tap the link we send to the new address.")
            }
            Section {
                Button("Send confirmation") { Task { await change() } }
                    .disabled(!valid)
                if let message { Text(message).font(.caption).foregroundStyle(Theme.scoreGreen) }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Change email")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func change() async {
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
}

// MARK: - Change phone

private struct ChangePhoneScreen: View {
    @State var phone: String
    var onSaved: (String) -> Void
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("Phone number", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .onChange(of: phone) { _, _ in saved = false }
                Button("Save number") {
                    Task {
                        if await SupabaseService.shared.setPhone(phone) {
                            saved = true
                            onSaved(phone)
                        } else {
                            ToastCenter.shared.show("Couldn't use that number — it may already be on Cini.")
                        }
                    }
                }
                .disabled(phone.filter(\.isNumber).count < 10)
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.scoreGreen)
                }
            } footer: {
                Text("Used only to help friends from your contacts find you on Cini — never shown on your profile or shared.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Phone number")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Change password

private struct ChangePasswordScreen: View {
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message: String?
    @State private var errorMessage: String?

    private var valid: Bool { newPassword.count >= 6 && newPassword == confirmPassword }

    var body: some View {
        Form {
            Section {
                SecureField("New password", text: $newPassword)
                SecureField("Confirm new password", text: $confirmPassword)
                Button("Change password") { Task { await change() } }
                    .disabled(!valid)
                if !newPassword.isEmpty && !valid {
                    Text(newPassword.count < 6 ? "At least 6 characters." : "Passwords don't match.")
                        .font(.caption).foregroundStyle(Theme.scoreRed)
                }
                if let message { Text(message).font(.caption).foregroundStyle(Theme.scoreGreen) }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Theater alerts

private struct TheaterAlertsScreen: View {
    @State private var homeZip: String?
    @State private var loaded = false
    @State private var detecting = false
    @State private var zipMessage: String?

    var body: some View {
        Form {
            Section {
                if let homeZip {
                    LabeledContent {
                        Text(homeZip).foregroundStyle(Theme.gray)
                    } label: {
                        Label("Your area", systemImage: "mappin.and.ellipse")
                    }
                    Button { Task { await detectArea() } } label: {
                        if detecting { ProgressView() } else { Text("Update my area") }
                    }
                    .disabled(detecting)
                    Button("Turn off alerts", role: .destructive) {
                        Task {
                            await SupabaseService.shared.setHomeZip(nil)
                            homeZip = nil; zipMessage = nil
                        }
                    }
                } else {
                    Button { Task { await detectArea() } } label: {
                        if detecting { ProgressView() }
                        else { Label("Turn on theater alerts", systemImage: "popcorn") }
                    }
                    .disabled(detecting)
                }
                if let zipMessage {
                    Text(zipMessage).font(.caption).foregroundStyle(Theme.scoreRed)
                }
            } footer: {
                Text("We'll notify you when a movie on your Want to Watch — new or old — is playing near you. Uses your location once to find your area.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Theater alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            homeZip = await SupabaseService.shared.homeZip()
        }
    }

    private func detectArea() async {
        zipMessage = nil
        detecting = true
        defer { detecting = false }
        do {
            let zip = try await LocationZip.shared.currentZip()
            await SupabaseService.shared.setHomeZip(zip)
            homeZip = zip
        } catch LocationZip.LocationError.denied {
            zipMessage = "Location is off for Cini — enable it in Settings to use theater alerts."
        } catch {
            zipMessage = "Couldn't find your area — try again."
        }
    }
}

// MARK: - Export

private struct ExportRow: View {
    @Environment(RankingStore.self) private var store
    @State private var exporting = false
    @State private var exportURLs: [URL] = []
    @State private var showShare = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task { await exportData() }
        } label: {
            HStack {
                Label("Export my movies", systemImage: "square.and.arrow.up.on.square")
                Spacer()
                if exporting { ProgressView() }
            }
        }
        .disabled(exporting)
        .sheet(isPresented: $showShare) { ActivityShareSheet(items: exportURLs) }
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed)
        }
    }

    private func exportData() async {
        errorMessage = nil
        exporting = true
        defer { exporting = false }
        do {
            let urls = try await CiniExporter.makeLetterboxdFiles(store: store)
            guard !urls.isEmpty else {
                errorMessage = "Nothing to export yet — rank or watchlist a movie first."
                return
            }
            exportURLs = urls
            showShare = true
        } catch {
            errorMessage = "Export failed — check your connection and try again."
        }
    }
}

/// One-tap system share sheet (ShareLink needs its items up front; the
/// export builds them on demand).
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
