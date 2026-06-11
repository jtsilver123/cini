import SwiftUI
import UserNotifications

/// Remote push: asks for permission after sign-in, registers with APNs,
/// stores the device token in Supabase (the send-push edge function fans
/// out to these tokens whenever a notification row is created), and shows
/// banners while the app is foregrounded.
final class PushManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Request permission and register. Safe to call repeatedly — iOS
    /// only prompts once, and re-registration refreshes a stale token.
    static func enable() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            guard granted else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await SupabaseService.shared.registerDeviceToken(token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator or entitlement issues — in-app notifications still work.
    }

    /// Show banners even when the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    /// Tapping a notification lands on its content: the movie page for
    /// likes/comments/recs/showtime alerts, the actor's profile for new
    /// followers. Works from cold launch too — the pending flags sit on
    /// the shared router until FeedView appears and consumes them.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run { TabRouter.shared.routePush(userInfo: userInfo) }
    }
}
