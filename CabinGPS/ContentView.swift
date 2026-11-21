import SwiftUI

private enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    @StateObject private var gps = FlightLocationManager()
    @State private var selectedAirport: Airport?
    @State private var favoriteCodes: Set<String> = FavoriteAirportsStore.loadCodes()
    @State private var allAirports: [Airport] = AirportStore.loadAirports()
    @State private var appearanceMode: AppearanceMode = .system
    @State private var isTracking = true
    @State private var showPosition = true
    @State private var showDestination = true
    @State private var showMap = true
    @State private var showAltitudeSpeed = true
    @State private var showAdvanced = false

    private var favoriteAirports: [Airport] {
        allAirports.filter { favoriteCodes.contains($0.iata) }
    }

    private var displayedLatitudeText: String {
        if let coord = gps.effectiveCoordinate {
            return String(format: "%.6f°", coord.latitude)
        }
        return gps.latitudeText
    }

    private var displayedLongitudeText: String {
        if let coord = gps.effectiveCoordinate {
            return String(format: "%.6f°", coord.longitude)
        }
        return gps.longitudeText
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Status Banner
                    HStack(spacing: 10) {
                        Image(
                            systemName: gps.isSimulatingFlight
                                ? "airplane"
                                : (gps.altitudeMeters != nil ? "airplane.circle.fill" : "antenna.radiowaves.left.and.right")
                        )
                        .font(.title2)
                        .foregroundStyle(gps.isSimulatingFlight ? .blue : (gps.altitudeMeters != nil ? .green : .orange))
                        Text(gps.statusMessage)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    // Collapsible Position Section
                    DisclosureGroup(isExpanded: $showPosition) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TelemetryTile(title: "Latitude", value: displayedLatitudeText)
                                TelemetryTile(title: "Longitude", value: displayedLongitudeText)
                            }

                            if let hAcc = gps.horizontalAccuracyMeters, !gps.isSimulatingFlight {
                                Text(String(format: "Horizontal accuracy: ±%.0f m", hAcc))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Position", systemImage: "location.fill")
                            .font(.headline)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // Collapsible Destination Calculator Section
                    DisclosureGroup(isExpanded: $showDestination) {
                        DestinationCalculatorContent(
                            currentCoordinate: gps.effectiveCoordinate,
                            speedMps: gps.effectiveSpeedMps,
                            selectedAirport: $selectedAirport,
                            favoriteCodes: $favoriteCodes
                        )
                        .padding(.top, 8)
                    } label: {
                        Label("Destination Calculator", systemImage: "airplane.arrival")
                            .font(.headline)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // Collapsible Offline Map Section
                    DisclosureGroup(isExpanded: $showMap) {
                        OfflineMapView(
                            currentCoordinate: gps.effectiveCoordinate,
                            courseDegrees: gps.effectiveCourseDegrees,
                            trackCoordinates: gps.effectiveTrackCoordinates,
                            destinationAirport: selectedAirport,
                            favoriteAirports: favoriteAirports,
                            speedMps: gps.effectiveSpeedMps
                        )
                        .padding(.top, 8)
                    } label: {
                        Label("Offline Map", systemImage: "map.fill")
                            .font(.headline)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // Collapsible Altitude & Speed Section
                    DisclosureGroup(isExpanded: $showAltitudeSpeed) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TelemetryTile(
                                    title: "Altitude (ft)",
                                    value: gps.altitudeFeet.map { String(format: "%.0f ft", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Altitude (m)",
                                    value: gps.altitudeMeters.map { String(format: "%.0f m", $0) } ?? "--"
                                )
                            }

                            HStack {
                                TelemetryTile(
                                    title: "Speed (kt)",
                                    value: gps.speedKnots.map { String(format: "%.0f kt", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Speed (km/h)",
                                    value: gps.speedKmh.map { String(format: "%.0f km/h", $0) } ?? "--"
                                )
                            }

                            HStack {
                                TelemetryTile(
                                    title: "Track / Course",
                                    value: gps.effectiveCourseDegrees.map { String(format: "%.0f°", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Vertical Acc.",
                                    value: gps.verticalAccuracyMeters.map { String(format: "±%.0f m", $0) } ?? "--"
                                )
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Altitude & Ground Speed", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.headline)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // Collapsible Advanced Section: Sensors -> Simulated Flight -> Theme
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TelemetryTile(
                                    title: "Pitch",
                                    value: gps.pitchDegrees.map { String(format: "%+.1f°", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Roll",
                                    value: gps.rollDegrees.map { String(format: "%+.1f°", $0) } ?? "--"
                                )
                            }

                            HStack {
                                TelemetryTile(
                                    title: "Vertical Accel",
                                    value: gps.verticalAccelerationG.map { String(format: "%+.2f g", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Total Vertical G",
                                    value: gps.verticalAccelerationG.map { String(format: "%.2f G", 1.0 + $0) } ?? "--"
                                )
                            }

                            HStack {
                                TelemetryTile(
                                    title: "Magnetic Heading",
                                    value: gps.magneticHeadingDegrees.map { String(format: "%.0f°", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "True Heading",
                                    value: gps.trueHeadingDegrees.map { String(format: "%.0f°", $0) } ?? "--"
                                )
                            }

                            HStack {
                                TelemetryTile(
                                    title: "Heading Acc.",
                                    value: gps.headingAccuracyDegrees.map { String(format: "±%.0f°", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Course Acc.",
                                    value: gps.courseAccuracyDegrees.map { String(format: "±%.0f°", $0) } ?? "--"
                                )
                            }

                            HStack {
                                TelemetryTile(
                                    title: "Speed Acc.",
                                    value: gps.speedAccuracyMps.map { String(format: "%.1f kt", $0 * 1.943844) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Barometer",
                                    value: gps.pressureHpa.map { String(format: "%.1f hPa", $0) } ?? "--"
                                )
                            }

                            HStack {
                                TelemetryTile(
                                    title: "Rel. Alt (Baro)",
                                    value: gps.relativeAltitudeMeters.map { String(format: "%+.1f m", $0) } ?? "--"
                                )
                                TelemetryTile(
                                    title: "Mag X / Y / Z",
                                    value: (gps.rawMagX != nil && gps.rawMagY != nil && gps.rawMagZ != nil)
                                        ? String(format: "%.0f / %.0f / %.0f", gps.rawMagX!, gps.rawMagY!, gps.rawMagZ!)
                                        : "--"
                                )
                            }

                            // Simulated Flight Controls
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("Simulated Flight", systemImage: "airplane")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    if gps.isSimulatingFlight {
                                        Text("\(Int(gps.simProgress * 100))%")
                                            .font(.caption.monospacedDigit().bold())
                                            .foregroundStyle(.blue)
                                    }
                                }

                                Picker("Time Warp", selection: $gps.simTimeMultiplier) {
                                    Text("10x").tag(10.0)
                                    Text("60x").tag(60.0)
                                    Text("300x").tag(300.0)
                                }
                                .pickerStyle(.segmented)

                                if gps.isSimulatingFlight {
                                    Button(role: .destructive) {
                                        gps.stopSimulatedFlight(resumeLiveGPS: isTracking)
                                    } label: {
                                        Label("Stop Simulation", systemImage: "stop.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                } else {
                                    Button {
                                        if let dest = selectedAirport {
                                            gps.startSimulatedFlight(to: dest)
                                        }
                                    } label: {
                                        Label(
                                            selectedAirport != nil
                                                ? "Fly to \(selectedAirport!.iata)"
                                                : "Select Destination First",
                                            systemImage: "play.fill"
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(selectedAirport == nil)
                                }
                            }
                            .padding(10)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))

                            // Theme Selector at Bottom of Advanced
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Theme", systemImage: "circle.lefthalf.filled")
                                    .font(.subheadline.bold())

                                Picker("Theme", selection: $appearanceMode) {
                                    ForEach(AppearanceMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(10)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Advanced", systemImage: "waveform.path.ecg")
                            .font(.headline)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // Timestamp & Controls
                    VStack(spacing: 12) {
                        if let updated = gps.lastUpdated {
                            Text("Last fix: \(updated.formatted(date: .omitted, time: .standard))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            if gps.isSimulatingFlight {
                                gps.stopSimulatedFlight(resumeLiveGPS: true)
                                isTracking = true
                            } else if isTracking {
                                gps.stopUpdates()
                                isTracking = false
                            } else {
                                gps.startUpdates()
                                isTracking = true
                            }
                        } label: {
                            Label(
                                gps.isSimulatingFlight
                                    ? "Exit Sim & Resume GPS"
                                    : (isTracking ? "Pause GPS" : "Resume GPS"),
                                systemImage: gps.isSimulatingFlight
                                    ? "antenna.radiowaves.left.and.right"
                                    : (isTracking ? "pause.fill" : "play.fill")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Offline Flight GPS")
            .onAppear {
                if allAirports.isEmpty {
                    allAirports = AirportStore.loadAirports()
                }
                gps.requestPermissionAndStart()
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
    }
}

private struct TelemetryTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
