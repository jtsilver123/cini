import SwiftUI

/// Beli-style two-level settings. This top screen is the menu — Your account,
/// Notifications, Privacy, Your app, Help — plus Log out. Each row opens a
/// focused sub-screen so nothing here feels crowded.
struct AccountSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var showLogoutConfirm = false
    @State private var showEditProfile = false

    var body: some View {
        Form {
            Section {
                // Edit Profile carries its own NavigationStack, so it's
                // presented as a sheet rather than pushed (pushing would
                // double-nest the navigation bar).
                actionRow("person.text.rectangle", "Your profile",
                          "Edit your photo, name, bio, and socials") { showEditProfile = true }
                settingsRow("person.crop.circle", "Your account",
                            "Change your email, phone, or password") { ManageAccountScreen() }
                settingsRow("bell.badge", "Notifications",
                            "Choose which notifications you get") { NotificationPreferencesView() }
                settingsRow("lock", "Privacy",
                            "Control who can see and follow you") { PrivacyScreen() }
                settingsRow("iphone", "Your app",
                            "Appearance, theater alerts, your data") { AppPreferencesScreen() }
                settingsRow("questionmark.circle", "Help",
                            "FAQ, support, and legal") { HelpScreen() }
            }

            Section {
                Button("Log out", role: .destructive) { showLogoutConfirm = true }
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Log out of Cini?", isPresented: $showLogoutConfirm) {
            Button("Log out", role: .destructive) { Task { await session.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showEditProfile) {
            if let profile = session.profile {
                EditProfileView(profile: profile, onSaved: { Task { await session.loadProfile() } })
            }
        }
    }

    /// Icon + title + descriptive subtitle, tappable through to a sub-screen.
    private func settingsRow<Destination: View>(_ icon: String, _ title: String, _ subtitle: String,
                                                @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            rowLabel(icon, title, subtitle)
        }
    }

    /// Same look as `settingsRow`, but runs an action (used for the "Your
    /// profile" row, which presents Edit Profile as a sheet).
    private func actionRow(_ icon: String, _ title: String, _ subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                rowLabel(icon, title, subtitle)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(Theme.marquee)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.gray)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Manage account (the account-specific editors + delete)

private struct ManageAccountScreen: View {
    @Environment(AppSession.self) private var session
    @State private var currentPhone = ""
    @State private var loaded = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                navRow("Change username", systemImage: "at",
                       value: session.profile.map { "@\($0.username)" }) { ChangeUsernameScreen() }
                navRow("Change email", systemImage: "envelope",
                       value: SupabaseService.shared.currentEmail) { ChangeEmailScreen() }
                navRow("Change phone number", systemImage: "phone",
                       value: currentPhone.isEmpty ? nil : currentPhone) {
                    ChangePhoneScreen(phone: currentPhone) { currentPhone = $0 }
                }
                navRow("Change password", systemImage: "lock") { ChangePasswordScreen() }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isDeleting ? "Deleting…" : "Delete my account")
                            Text("Permanently delete your account")
                                .font(.caption).foregroundStyle(Theme.gray)
                        }
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
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Manage account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete your account forever?", isPresented: $showDeleteConfirm) {
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
            let detail = "\(error)".lowercased()
            errorMessage = (detail.contains("network") || detail.contains("offline") || detail.contains("timed out"))
                ? "Couldn't delete your account — you're offline. Check your connection and try again."
                : "Couldn't delete your account — try again, or email jtsilver123@gmail.com and we'll remove it."
        }
    }
}

// MARK: - Privacy

private struct PrivacyScreen: View {
    @Environment(AppSession.self) private var session
    @State private var isPrivate = false
    @State private var loaded = false
    @State private var forgotContacts = false
    @State private var revertingPrivate = false

    var body: some View {
        Form {
            Section {
                Toggle("Private account", isOn: $isPrivate)
                    .tint(Theme.velvet)
                    .onChange(of: isPrivate) { _, newValue in
                        guard loaded else { return }   // ignore the initial load assignment
                        if revertingPrivate { revertingPrivate = false; return }
                        Task {
                            do {
                                try await SupabaseService.shared.updateProfile(ProfileUpdate(is_private: newValue))
                                await session.loadProfile()
                            } catch {
                                // A privacy toggle that LOOKS changed but didn't
                                // save is dangerous — surface it and revert.
                                ToastCenter.shared.saveFailed()
                                revertingPrivate = true
                                isPrivate = !newValue
                            }
                        }
                    }
            } footer: {
                Text("When on, only approved followers see your rankings and activity — everyone else has to send a follow request you approve.")
            }
            Section {
                Button {
                    Task {
                        do {
                            try await SupabaseService.shared.forgetContacts()
                            forgotContacts = true
                        } catch {
                            // A privacy claim must be true — never show
                            // "removed" while the server still has the hashes.
                            ToastCenter.shared.saveFailed()
                        }
                    }
                } label: {
                    Label(forgotContacts ? "Synced contacts removed" : "Remove synced contacts",
                          systemImage: forgotContacts ? "checkmark.circle.fill" : "person.crop.circle.badge.xmark")
                }
                .disabled(forgotContacts)
            } footer: {
                Text("If you used Find Friends, we keep a scrambled version of your contacts' phone numbers (never their names) so we can tell you when a friend joins. We never share them, you can remove them any time, and they're deleted if you delete your account.")
            }
            Section {
                Link(destination: URL(string: "https://trycini.com/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isPrivate = session.profile?.isPrivate ?? false
            loaded = true
        }
    }
}

// MARK: - Your app (preferences)

private struct AppPreferencesScreen: View {
    @AppStorage("cini.appearance") private var appearance = "dark"
    @AppStorage("feed.hideWatchingStories") private var hideWatchingStories = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker(selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Match device").tag("system")
                } label: { Label("Theme", systemImage: "circle.lefthalf.filled") }
            }
            Section("Feed") {
                Toggle(isOn: $hideWatchingStories) {
                    Label("Hide \u{201C}Friends are watching\u{201D}", systemImage: "circle.dashed")
                }
                .tint(Theme.velvet)
            }
            Section {
                NavigationLink {
                    TheaterAlertsScreen()
                } label: { Label("Theater alerts", systemImage: "popcorn") }
            }
            Section("Your data") {
                ExportRow()
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Your app")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Help

private struct HelpScreen: View {
    private struct QA: Identifiable { let id = UUID(); let q: String; let a: String }

    // Real questions about how Cini actually works — kept accurate to the app.
    private let faqs: [QA] = [
        QA(q: "How does ranking work?",
           a: "Instead of star ratings, Cini asks “which did you like more?” between two titles you've seen. A few quick comparisons slot the new one exactly where it belongs, and its spot in your list becomes a score out of 10."),
        QA(q: "Where do the scores come from?",
           a: "A title's score reflects where it sits in your own ranked list — not an absolute rating. As you rank more, scores settle into place. The same title can score differently for you and a friend."),
        QA(q: "Are movies and TV ranked together?",
           a: "No — movies and shows are ranked in separate lists, so a film never has to compete head-to-head with a series."),
        QA(q: "What's a Rec Score?",
           a: "It's our prediction of how much you'll like something you haven't seen yet, based on the taste your rankings reveal. It needs a handful of ranked titles to get accurate."),
        QA(q: "Where's the average score for a title?",
           a: "It's on every title's page, under the score. Cini shows the full crowd average on any title that has enough ratings — a brand-new or obscure title just may not have one yet."),
        QA(q: "How do I make my account private?",
           a: "Settings → Privacy → Private account. After that, people send a follow request you can approve or decline, and only approved followers see your activity."),
        QA(q: "How do I find friends?",
           a: "Search for usernames, or tap Invite friends to match your contacts. We only ever store one-way hashes of phone numbers — never names or readable numbers — and you can remove them anytime in Privacy."),
        QA(q: "Can I bring my Letterboxd history?",
           a: "Yes. Open Import (from your profile menu), drag in your Letterboxd export, and we'll queue your films and lists for you to rank."),
        QA(q: "How do streaks work?",
           a: "Rank at least one title during a week to keep your streak going. Miss a week and it resets — we'll nudge you before it lapses."),
        QA(q: "How do I delete my account?",
           a: "Settings → Manage account → Delete account. It permanently removes your rankings, Want to Watch, and followers — there's no undo."),
    ]

    var body: some View {
        Form {
            Section("Frequently asked") {
                ForEach(faqs) { item in
                    DisclosureGroup {
                        Text(item.a)
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                            .padding(.vertical, 4)
                    } label: {
                        Text(item.q)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.marquee)
                }
            }

            Section("Still need help?") {
                Link(destination: URL(string: "mailto:jtsilver123@gmail.com?subject=Cini%20support")!) {
                    Label("Contact support", systemImage: "envelope")
                }
                Link(destination: URL(string: "https://trycini.com/terms.html")!) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
                Link(destination: URL(string: "https://trycini.com/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label("Movie data by TMDB", systemImage: "film")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Change email

private struct ChangeEmailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newEmail = ""
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var sending = false

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
                Button { Task { await change() } } label: {
                    HStack {
                        Text("Send confirmation")
                        if sending { Spacer(); ProgressView() }
                    }
                }
                .disabled(!valid || sending)
                if let message { Text(message).font(.caption).foregroundStyle(Theme.scoreGreen) }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed) }
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Change email")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func change() async {
        message = nil; errorMessage = nil
        sending = true
        defer { sending = false }
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

// MARK: - Change username

private struct ChangeUsernameScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var availability: Availability = .unknown
    @State private var availabilityTask: Task<Void, Never>?
    @State private var saving = false
    @State private var errorMessage: String?

    private enum Availability { case unknown, checking, available, taken }

    private var current: String { session.profile?.username ?? "" }
    private var valid: Bool {
        username.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(Theme.gray)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: username) { _, new in
                            username = new.lowercased().filter { $0.isLowercase || $0.isNumber || $0 == "_" }
                            checkAvailability()
                        }
                    switch availability {
                    case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.scoreGreen)
                    case .taken: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.scoreRed)
                    case .checking: ProgressView().controlSize(.small)
                    case .unknown: EmptyView()
                    }
                }
            } footer: {
                Text("3–20 characters: lowercase letters, numbers, and underscores. Your old @handle stops working once you change it.")
            }
            Section {
                Button { Task { await save() } } label: {
                    HStack {
                        Text(saving ? "Saving…" : "Save username")
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(!valid || username == current || availability == .taken || saving)
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed) }
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Change username")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if username.isEmpty { username = current } }
    }

    private func checkAvailability() {
        availabilityTask?.cancel()
        guard valid, username != current else { availability = .unknown; return }
        availability = .checking
        let candidate = username
        availabilityTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let free = await SupabaseService.shared.usernameAvailable(candidate)
            guard candidate == username else { return }
            availability = free ? .available : .taken
        }
    }

    private func save() async {
        saving = true; errorMessage = nil
        defer { saving = false }
        do {
            try await SupabaseService.shared.updateProfile(ProfileUpdate(username: username))
            await session.loadProfile()
            ToastCenter.shared.show("Username updated to @\(username)")
            dismiss()
        } catch {
            errorMessage = "Couldn't change your username — it may be taken. Try another."
        }
    }
}

// MARK: - Change phone

private struct ChangePhoneScreen: View {
    @State private var country: CountryCode
    @State private var phone: String
    var onSaved: (String) -> Void
    @State private var saved = false
    @State private var saving = false

    /// Parse the stored E.164 number (signup saves "+44…", not bare digits) back
    /// into its country + national part so a non-US number re-opens correctly.
    init(phone: String, onSaved: @escaping (String) -> Void) {
        self.onSaved = onSaved
        let e164 = phone.hasPrefix("+") ? phone : "+" + PhoneNumber.digits(phone)
        let matched = CountryCode.common
            .filter { e164.hasPrefix($0.dial) }
            .sorted { $0.dial.count > $1.dial.count }
            .first ?? .usDefault
        // +1 is shared by US/Canada — prefer the US entry.
        let resolved = matched.dial == "+1" ? CountryCode.usDefault : matched
        let national = PhoneNumber.digits(String(e164.dropFirst(resolved.dial.count)))
        _country = State(initialValue: resolved)
        _phone = State(initialValue: resolved.dial == "+1"
                       ? PhoneNumber.formattedLive(national) : national)
    }

    /// Full E.164 number sent to the server (mirrors AuthView): strip a single
    /// national trunk "0" outside the +1 plan so "+44 07911…" becomes "+447911…".
    private var e164Phone: String {
        let digits = PhoneNumber.digits(phone)
        if country.dial != "+1", digits.hasPrefix("0") {
            return country.dial + String(digits.dropFirst())
        }
        return country.dial + digits
    }

    private func reformat(_ new: String) {
        if country.dial == "+1" {
            let f = PhoneNumber.formattedLive(new)
            if f != phone { phone = f }
        } else {
            let d = String(PhoneNumber.digits(new).prefix(14))
            if d != phone { phone = d }
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(CountryCode.common) { c in
                            Button("\(c.flag)  \(c.name)  \(c.dial)") {
                                country = c
                                saved = false
                                reformat(phone)
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
                        .onChange(of: phone) { _, new in
                            saved = false
                            reformat(new)
                        }
                }
                if PhoneNumber.digits(phone).count >= 10 && !PhoneNumber.isValid(phone, dial: country.dial) {
                    Text("That doesn't look like a valid number — check for typos.")
                        .font(.caption).foregroundStyle(Theme.scoreRed)
                }
                Button { Task { await save() } } label: {
                    HStack {
                        Text("Save number")
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(!PhoneNumber.isValid(phone, dial: country.dial) || saving)
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.scoreGreen)
                }
            } footer: {
                Text("Used only to help friends from your contacts find you on Cini — never shown on your profile or shared.")
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Phone number")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await SupabaseService.shared.setPhone(e164Phone) {
            saved = true
            onSaved(e164Phone)
        } else {
            ToastCenter.shared.show("Couldn't use that number — it may already be on Cini.")
        }
    }
}

// MARK: - Change password

private struct ChangePasswordScreen: View {
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var reveal = false

    private var valid: Bool { PasswordPolicy.isValid(newPassword) && newPassword == confirmPassword }

    var body: some View {
        Form {
            Section {
                HStack {
                    Group {
                        if reveal { TextField("New password", text: $newPassword) }
                        else { SecureField("New password", text: $newPassword) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(Theme.gray)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
                }
                Group {
                    if reveal { TextField("Confirm new password", text: $confirmPassword) }
                    else { SecureField("Confirm new password", text: $confirmPassword) }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // Same rules as sign-up, shown live.
                ruleRow(PasswordPolicy.lengthRule, PasswordPolicy.hasLength(newPassword))
                if !confirmPassword.isEmpty && newPassword != confirmPassword {
                    ruleRow("Passwords match", false)
                }
                Button("Change password") { Task { await change() } }
                    .disabled(!valid)
                if let message { Text(message).font(.caption).foregroundStyle(Theme.scoreGreen) }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed) }
            }
        }
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ruleRow(_ text: String, _ met: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? Theme.scoreGreen : Theme.gray)
            Text(text).foregroundStyle(met ? Theme.ink : Theme.gray)
        }
        .font(.caption)
    }

    private func change() async {
        message = nil; errorMessage = nil
        do {
            try await SupabaseService.shared.updatePassword(newPassword)
            message = "Password updated — you're still signed in."
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
    @State private var confirmOff = false

    var body: some View {
        Form {
            Section {
                if let zip = homeZip {
                    LabeledContent {
                        Text(zip).foregroundStyle(Theme.gray)
                    } label: {
                        Label("Your area", systemImage: "mappin.and.ellipse")
                    }
                    Button { Task { await detectArea() } } label: {
                        if detecting { ProgressView() } else { Text("Update my area") }
                    }
                    .disabled(detecting)
                    Button("Turn off alerts", role: .destructive) { confirmOff = true }
                        .alert("Turn off theater alerts?", isPresented: $confirmOff) {
                            Button("Turn off alerts", role: .destructive) {
                                Task {
                                    await SupabaseService.shared.setHomeZip(nil)
                                    homeZip = nil; zipMessage = nil
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("You'll stop getting notified when your Want to Watch titles play near you.")
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
        .nativeContentWidth()
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
                Label("Export my movies & TV", systemImage: "square.and.arrow.up.on.square")
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
                errorMessage = "Nothing to export yet — rank or save a movie or show first."
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
