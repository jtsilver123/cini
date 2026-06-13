import Foundation
import Network
import Observation

/// App-wide connectivity. Drives the slim "No internet connection" banner
/// in RootTabView; individual screens still handle their own load
/// failures, but this is the one honest, always-visible offline signal.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Starts true so a brief startup probe never flashes the banner; the
    /// monitor corrects it within a moment of launch.
    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cini.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }
}
