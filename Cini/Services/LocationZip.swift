import CoreLocation

/// One-shot "where am I" → zipcode, for autofilling showtime searches.
/// Requests when-in-use permission on first tap; the location is used
/// once and never stored beyond the zip the user already sees.
@MainActor
final class LocationZip: NSObject, CLLocationManagerDelegate {
    static let shared = LocationZip()

    enum LocationError: Error {
        case denied
        case unavailable
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func currentZip() async throws -> String {
        let location = try await currentLocation()
        guard let zip = try await CLGeocoder()
            .reverseGeocodeLocation(location).first?.postalCode else {
            throw LocationError.unavailable
        }
        return zip
    }

    private func currentLocation() async throws -> CLLocation {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.first {
                continuation?.resume(returning: location)
            } else {
                continuation?.resume(throwing: LocationError.unavailable)
            }
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(throwing: LocationError.unavailable)
            continuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // If the user denies the fresh prompt, fail fast instead of
            // leaving the spinner running until timeout.
            if manager.authorizationStatus == .denied, continuation != nil {
                continuation?.resume(throwing: LocationError.denied)
                continuation = nil
            }
        }
    }
}
