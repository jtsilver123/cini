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
    private var awaitingAuthorization = false

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
            // Ask first; the actual location request happens in the
            // authorization callback. Requesting while undetermined races
            // the permission prompt and fails on the user's first tap.
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.awaitingAuthorization = true
                self.manager.requestWhenInUseAuthorization()
            }
        default:
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.manager.requestLocation()
            }
        }
    }

    private func resume(with result: Result<CLLocation, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        awaitingAuthorization = false
        pending.resume(with: result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.first {
                resume(with: .success(location))
            } else {
                resume(with: .failure(LocationError.unavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            resume(with: .failure(LocationError.unavailable))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if awaitingAuthorization {
                    awaitingAuthorization = false
                    manager.requestLocation()
                }
            case .denied, .restricted:
                resume(with: .failure(LocationError.denied))
            default:
                break   // still undetermined: keep waiting for the prompt
            }
        }
    }
}
