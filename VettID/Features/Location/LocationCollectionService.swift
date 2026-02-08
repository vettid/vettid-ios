import Foundation
import CoreLocation

// MARK: - Location Collection Service

class LocationCollectionService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationCollectionService()

    private let locationManager = CLLocationManager()
    private var ownerSpaceClient: OwnerSpaceClient?
    private var locationSettings: LocationSettings = .default

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isCollecting = false
    @Published var lastError: String?

    private var collectionTimer: Timer?

    // MARK: - Initialization

    override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Configuration

    func configure(ownerSpaceClient: OwnerSpaceClient, settings: LocationSettings) {
        self.ownerSpaceClient = ownerSpaceClient
        self.locationSettings = settings

        locationManager.desiredAccuracy = settings.precision == .exact
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyHundredMeters

        locationManager.distanceFilter = Double(settings.displacementThreshold.meters)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = true
    }

    func updateSettings(_ settings: LocationSettings) {
        self.locationSettings = settings

        locationManager.desiredAccuracy = settings.precision == .exact
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyHundredMeters

        locationManager.distanceFilter = Double(settings.displacementThreshold.meters)

        if settings.trackingEnabled && isCollecting {
            restartCollection()
        } else if !settings.trackingEnabled && isCollecting {
            stopCollecting()
        }
    }

    // MARK: - Permissions

    var hasLocationPermission: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var hasBackgroundPermission: Bool {
        authorizationStatus == .authorizedAlways
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestAlwaysPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Collection Control

    func startCollecting() {
        guard hasLocationPermission else {
            requestPermission()
            return
        }

        guard locationSettings.trackingEnabled else { return }

        isCollecting = true
        lastError = nil

        // Use significant location changes for background efficiency
        if hasBackgroundPermission {
            locationManager.startMonitoringSignificantLocationChanges()
        }

        // Also start periodic timer-based collection
        startCollectionTimer()

        // Get an initial location
        locationManager.requestLocation()
    }

    func stopCollecting() {
        isCollecting = false
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopUpdatingLocation()
        collectionTimer?.invalidate()
        collectionTimer = nil
    }

    private func restartCollection() {
        stopCollecting()
        startCollecting()
    }

    private func startCollectionTimer() {
        collectionTimer?.invalidate()
        let interval = TimeInterval(locationSettings.updateFrequency.minutes * 60)
        collectionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.locationManager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        processLocation(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
        #if DEBUG
        print("[LocationCollectionService] Location error: \(error)")
        #endif
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        if hasLocationPermission && locationSettings.trackingEnabled && !isCollecting {
            startCollecting()
        }
    }

    // MARK: - Location Processing

    private func processLocation(_ location: CLLocation) {
        // Check displacement threshold
        if let lastLat = locationSettings.lastKnownLatitude,
           let lastLon = locationSettings.lastKnownLongitude {
            let lastLocation = CLLocation(latitude: lastLat, longitude: lastLon)
            let distance = location.distance(from: lastLocation)

            if distance < Double(locationSettings.displacementThreshold.meters) {
                return // Not enough displacement
            }
        }

        // Round coordinates to configured precision
        let precision = locationSettings.precision
        let factor = pow(10.0, Double(precision.decimalPlaces))
        let roundedLat = (location.coordinate.latitude * factor).rounded() / factor
        let roundedLon = (location.coordinate.longitude * factor).rounded() / factor

        // Send to vault
        let request = LocationAddRequest(
            latitude: roundedLat,
            longitude: roundedLon,
            accuracy: Float(location.horizontalAccuracy),
            altitude: location.altitude,
            speed: location.speed >= 0 ? Float(location.speed) : nil,
            timestamp: location.timestamp.timeIntervalSince1970,
            source: location.sourceType
        )

        Task {
            do {
                try await ownerSpaceClient?.sendToVault(request, topic: "location.add")
            } catch {
                await MainActor.run {
                    self.lastError = "Failed to send location: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - CLLocation Extension

extension CLLocation {
    var sourceType: String {
        if horizontalAccuracy <= 10 {
            return "gps"
        } else if horizontalAccuracy <= 100 {
            return "wifi"
        } else {
            return "network"
        }
    }
}
