import SwiftUI
import UserNotifications

/// Remote push: asks for permission after sign-in, registers with APNs,
/// stores the device token in Supabase (the send-push edge function fans
/// out to these tokens whenever a notification row is created), and shows
/// banners while the app is foregrounded.
final class PushManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// The token registered for THIS device — sign-out deletes it so a
    /// shared phone never keeps receiving the old account's pushes.
    private(set) static var currentToken: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // NOTE: no applicationDidBecomeActive here — that delegate method never
    // fires under the SwiftUI scene lifecycle. The foreground badge clear
    // lives in FeedView's scenePhase observer instead.

    /// Zero out the app-icon badge (no-op error handling — a failed badge
    /// clear is cosmetic and must never surface to the user).
    static func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Prompt for permission (primed by the onboarding step) and register on
    /// grant. Returns whether it was granted. iOS only shows the dialog once.
    @discardableResult
    static func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
        return granted
    }

    /// Register for remote notifications ONLY if permission is already
    /// granted — never prompts. Used at sign-in so returning users refresh
    /// their token without a surprise dialog (the prompt lives in onboarding).
    static func registerIfAuthorized() {
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Current OS notification authorization (for reflecting state in UI).
    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.currentToken = token
        Task {
            // A silently dropped registration = zero pushes with no trace.
            // Log the failure and retry once — APNs registration happens at
            // sign-in, exactly when a flaky connection is most likely.
            do { try await SupabaseService.shared.registerDeviceToken(token) }
            catch {
                SupabaseService.logSwallowed("registerDeviceToken", error)
                try? await Task.sleep(for: .seconds(5))
                do { try await SupabaseService.shared.registerDeviceToken(token) }
                catch { SupabaseService.logSwallowed("registerDeviceToken.retry", error) }
            }
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator or entitlement issues — in-app notifications still work.
    }

    /// Show banners even when the app is open — and `.list` so a notification
    /// that arrives in the foreground still lands in the iOS Notification
    /// Center (without it, foreground pushes vanish after the banner).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    /// Tapping a notification lands on its content: the movie page for
    /// likes/comments/recs/showtime alerts, the actor's profile for new
    /// followers. Works from cold launch too — the pending flags sit on
    /// the shared router until FeedView appears and consumes them.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run { TabRouter.shared.routePush(userInfo: userInfo) }
        Self.clearBadge()
    }
}
