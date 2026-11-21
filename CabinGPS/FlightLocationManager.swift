import Foundation
import CoreLocation
import CoreMotion
import Combine

@MainActor
final class FlightLocationManager: NSObject, ObservableObject {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var trackCoordinates: [CLLocationCoordinate2D] = []
    @Published var latitudeText: String = "--"
    @Published var longitudeText: String = "--"
    @Published var altitudeMeters: Double?
    @Published var speedMps: Double?
    @Published var courseDegrees: Double?
    @Published var courseAccuracyDegrees: Double?
    @Published var speedAccuracyMps: Double?
    @Published var horizontalAccuracyMeters: Double?
    @Published var verticalAccuracyMeters: Double?
    @Published var magneticHeadingDegrees: Double?
    @Published var trueHeadingDegrees: Double?
    @Published var headingAccuracyDegrees: Double?
    @Published var rawMagX: Double?
    @Published var rawMagY: Double?
    @Published var rawMagZ: Double?
    @Published var pressureKpa: Double?
    @Published var relativeAltitudeMeters: Double?
    @Published var pitchDegrees: Double?
    @Published var rollDegrees: Double?
    @Published var verticalAccelerationG: Double?
    @Published var lastUpdated: Date?
    @Published var statusMessage: String = "Initializing GPS..."

    // Flight simulation state
    @Published var isSimulatingFlight: Bool = false
    @Published var simProgress: Double = 0.0
    @Published var simCruiseSpeedMps: Double = 230.0
    @Published var simTimeMultiplier: Double = 60.0

    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private var isAltimeterActive = false

    private var simTimer: Timer?
    private var simStartCoordinate: CLLocationCoordinate2D?
    private var simTargetAirport: Airport?
    private var simTrackCoordinates: [CLLocationCoordinate2D] = []
    private var simCourse: Double?
    private var simCurrentCoord: CLLocationCoordinate2D?

    var effectiveCoordinate: CLLocationCoordinate2D? {
        isSimulatingFlight ? simCurrentCoord : currentCoordinate
    }

    var effectiveCourseDegrees: Double? {
        isSimulatingFlight ? simCourse : courseDegrees
    }

    var effectiveTrackCoordinates: [CLLocationCoordinate2D] {
        isSimulatingFlight ? simTrackCoordinates : trackCoordinates
    }

    var effectiveSpeedMps: Double? {
        isSimulatingFlight ? simCruiseSpeedMps : speedMps
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .airborne
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = 1
        motionManager.deviceMotionUpdateInterval = 0.2
        authorizationStatus = locationManager.authorizationStatus
    }

    func requestPermissionAndStart() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            statusMessage = "Requesting location permission..."
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates()
        case .denied, .restricted:
            statusMessage = "Location access denied. Enable it in Settings > Privacy & Security > Location Services."
        @unknown default:
            statusMessage = "Unknown authorization status."
        }
    }

    func startUpdates() {
        statusMessage = "Checking Location Services..."

        Task.detached(priority: .userInitiated) {
            let servicesEnabled = CLLocationManager.locationServicesEnabled()
            let headingAvailable = CLLocationManager.headingAvailable()

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard servicesEnabled else {
                    self.statusMessage = "Location Services are turned off on this device."
                    return
                }

                self.statusMessage = "Searching for GPS satellites (stay near a window)..."
                self.locationManager.startUpdatingLocation()

                if headingAvailable {
                    self.locationManager.startUpdatingHeading()
                }

                self.startBarometerIfAvailable()
                self.startDeviceMotionIfAvailable()
            }
        }
    }

    func stopUpdates() {
        locationManager.stopUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.stopUpdatingHeading()
        }
        stopBarometer()
        stopDeviceMotion()
        statusMessage = "GPS updates paused."
    }

    func clearTrack() {
        trackCoordinates.removeAll()
        if let current = currentCoordinate {
            trackCoordinates.append(current)
        }
    }

    // MARK: - Simulated Flight

    func startSimulatedFlight(to destination: Airport, from origin: CLLocationCoordinate2D? = nil) {
        stopSimulatedFlight(resumeLiveGPS: false)
        stopUpdates()

        let start = origin
            ?? currentCoordinate
            ?? CLLocationCoordinate2D(latitude: 52.3086, longitude: 4.7639)

        simStartCoordinate = start
        simTargetAirport = destination
        simCurrentCoord = start
        simProgress = 0.0
        simTrackCoordinates = [start]
        simCourse = Self.initialBearingDegrees(from: start, to: destination.coordinate)
        isSimulatingFlight = true
        lastUpdated = Date()
        statusMessage = "Simulating flight to \(destination.iata) (\(Int(simTimeMultiplier))x)"

        let tickInterval: TimeInterval = 0.25
                simTimer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.stepSimulation(deltaRealSeconds: tickInterval)
                    }
                }
                if let simTimer {
                    RunLoop.main.add(simTimer, forMode: .common)
                }
    }

    func stopSimulatedFlight(resumeLiveGPS: Bool = true) {
        simTimer?.invalidate()
        simTimer = nil
        isSimulatingFlight = false
        simProgress = 0.0
        simStartCoordinate = nil
        simTargetAirport = nil
        simCurrentCoord = nil
        simCourse = nil
        simTrackCoordinates.removeAll()

        if resumeLiveGPS {
            requestPermissionAndStart()
        }
    }

    private func stepSimulation(deltaRealSeconds: TimeInterval) {
        guard isSimulatingFlight,
              let start = simStartCoordinate,
              let dest = simTargetAirport else { return }

        let totalMeters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: dest.coordinate.latitude, longitude: dest.coordinate.longitude))

        guard totalMeters > 10 else {
            simCurrentCoord = dest.coordinate
            simProgress = 1.0
            statusMessage = "Arrived at \(dest.iata) (Simulation complete)"
            simTimer?.invalidate()
            simTimer = nil
            return
        }

        let simulatedMetersMoved = simCruiseSpeedMps * deltaRealSeconds * simTimeMultiplier
        let fractionDelta = simulatedMetersMoved / totalMeters
        simProgress = min(simProgress + fractionDelta, 1.0)

        let nextCoord = Self.interpolateGreatCircle(from: start, to: dest.coordinate, fraction: simProgress)
        simCourse = Self.initialBearingDegrees(from: nextCoord, to: dest.coordinate)
        simCurrentCoord = nextCoord
        lastUpdated = Date()

        if let last = simTrackCoordinates.last {
            let dist = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: nextCoord.latitude, longitude: nextCoord.longitude))
            if dist >= 500 || simProgress >= 1.0 {
                simTrackCoordinates.append(nextCoord)
            }
        } else {
            simTrackCoordinates.append(nextCoord)
        }

        if simProgress >= 1.0 {
            statusMessage = "Arrived at \(dest.iata) (Simulation complete)"
            simTimer?.invalidate()
            simTimer = nil
        }
    }

    private static func interpolateGreatCircle(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        fraction t: Double
    ) -> CLLocationCoordinate2D {
        let clampedT = min(max(t, 0.0), 1.0)
        let lat1 = start.latitude * .pi / 180.0
        let lon1 = start.longitude * .pi / 180.0
        let lat2 = end.latitude * .pi / 180.0
        let lon2 = end.longitude * .pi / 180.0

        let dLat = lat2 - lat1
        let dLon = lon2 - lon1
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let delta = 2 * atan2(sqrt(a), sqrt(max(0.0, 1.0 - a)))

        guard delta > 1e-9 else {
            return end
        }

        let sinDelta = sin(delta)
        let weightA = sin((1.0 - clampedT) * delta) / sinDelta
        let weightB = sin(clampedT * delta) / sinDelta

        let x = weightA * cos(lat1) * cos(lon1) + weightB * cos(lat2) * cos(lon2)
        let y = weightA * cos(lat1) * sin(lon1) + weightB * cos(lat2) * sin(lon2)
        let z = weightA * sin(lat1) + weightB * sin(lat2)

        let resLat = atan2(z, sqrt(x * x + y * y)) * 180.0 / .pi
        let resLon = atan2(y, x) * 180.0 / .pi
        return CLLocationCoordinate2D(latitude: resLat, longitude: resLon)
    }

    private static func initialBearingDegrees(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180.0
        let lon1 = start.longitude * .pi / 180.0
        let lat2 = end.latitude * .pi / 180.0
        let lon2 = end.longitude * .pi / 180.0
        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    // MARK: - Barometer & Motion

    private func startBarometerIfAvailable() {
        guard CMAltimeter.isRelativeAltitudeAvailable(), !isAltimeterActive else { return }
        isAltimeterActive = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            Task { @MainActor in
                self.pressureKpa = data.pressure.doubleValue
                self.relativeAltitudeMeters = data.relativeAltitude.doubleValue
            }
        }
    }

    private func stopBarometer() {
        guard isAltimeterActive else { return }
        altimeter.stopRelativeAltitudeUpdates()
        isAltimeterActive = false
    }

    private func startDeviceMotionIfAvailable() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }
            Task { @MainActor in
                let radToDeg = 180.0 / .pi
                self.pitchDegrees = motion.attitude.pitch * radToDeg
                self.rollDegrees = motion.attitude.roll * radToDeg
                self.verticalAccelerationG = motion.userAcceleration.z
            }
        }
    }

    private func stopDeviceMotion() {
        guard motionManager.isDeviceMotionActive else { return }
        motionManager.stopDeviceMotionUpdates()
    }

    // Helpful conversions
    var altitudeFeet: Double? {
        altitudeMeters.map { $0 * 3.28084 }
    }

    var speedKnots: Double? {
        guard let spd = effectiveSpeedMps, spd >= 0 else { return nil }
        return spd * 1.943844
    }

    var speedKmh: Double? {
        guard let spd = effectiveSpeedMps, spd >= 0 else { return nil }
        return spd * 3.6
    }

    var pressureHpa: Double? {
        pressureKpa.map { $0 * 10.0 }
    }
}

extension FlightLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            guard !self.isSimulatingFlight else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.startUpdates()
            case .denied, .restricted:
                self.statusMessage = "Location permission denied in iOS Settings."
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }

        Task { @MainActor in
            guard !self.isSimulatingFlight else { return }
            guard latest.horizontalAccuracy >= 0 else {
                self.statusMessage = "Acquiring valid GPS fix..."
                return
            }

            let coord = latest.coordinate
            self.currentCoordinate = coord
            self.latitudeText = String(format: "%.6f°", coord.latitude)
            self.longitudeText = String(format: "%.6f°", coord.longitude)
            self.horizontalAccuracyMeters = latest.horizontalAccuracy

            if let last = self.trackCoordinates.last {
                let dist = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                if dist >= 250 {
                    self.trackCoordinates.append(coord)
                }
            } else {
                self.trackCoordinates.append(coord)
            }

            if latest.verticalAccuracy >= 0 {
                self.altitudeMeters = latest.altitude
                self.verticalAccuracyMeters = latest.verticalAccuracy
            } else {
                self.altitudeMeters = nil
                self.verticalAccuracyMeters = nil
            }

            if latest.speed >= 0 {
                self.speedMps = latest.speed
            } else {
                self.speedMps = nil
            }

            if latest.speedAccuracy >= 0 {
                self.speedAccuracyMps = latest.speedAccuracy
            } else {
                self.speedAccuracyMps = nil
            }

            if latest.course >= 0 {
                self.courseDegrees = latest.course
            } else {
                self.courseDegrees = nil
            }

            if latest.courseAccuracy >= 0 {
                self.courseAccuracyDegrees = latest.courseAccuracy
            } else {
                self.courseAccuracyDegrees = nil
            }

            self.lastUpdated = latest.timestamp
            self.statusMessage = "GPS lock active"
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            guard newHeading.headingAccuracy >= 0 else {
                self.headingAccuracyDegrees = nil
                return
            }
            self.magneticHeadingDegrees = newHeading.magneticHeading
            self.trueHeadingDegrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : nil
            self.headingAccuracyDegrees = newHeading.headingAccuracy
            self.rawMagX = newHeading.x
            self.rawMagY = newHeading.y
            self.rawMagZ = newHeading.z
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard !self.isSimulatingFlight else { return }
            let clError = error as? CLError
            if clError?.code == .locationUnknown {
                self.statusMessage = "Searching for satellite signal..."
            } else {
                self.statusMessage = "GPS error: \(error.localizedDescription)"
            }
        }
    }
}
