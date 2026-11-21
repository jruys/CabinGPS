import SwiftUI
import CoreLocation

struct Airport: Identifiable, Codable, Hashable {
    let iata: String
    let name: String
    let city: String
    let lat: Double
    let lon: Double

    var id: String { iata }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

enum FavoriteAirportsStore {
    private static let storageKey = "LLocation.FavoriteAirportIATAs"

    static func loadCodes() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        let parts = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    static func saveCodes(_ codes: Set<String>) {
        let serialized = codes.sorted().joined(separator: ",")
        UserDefaults.standard.set(serialized, forKey: storageKey)
    }
}

enum AirportStore {
    static let fallbackAirports: [Airport] = [
        Airport(iata: "AMS", name: "Amsterdam Schiphol", city: "Amsterdam", lat: 52.3086, lon: 4.7639),
        Airport(iata: "LHR", name: "London Heathrow", city: "London", lat: 51.4700, lon: -0.4543),
        Airport(iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris", lat: 49.0097, lon: 2.5479),
        Airport(iata: "FRA", name: "Frankfurt Airport", city: "Frankfurt", lat: 50.0379, lon: 8.5622),
        Airport(iata: "MAD", name: "Adolfo Suárez Madrid–Barajas", city: "Madrid", lat: 40.4983, lon: -3.5676),
        Airport(iata: "FCO", name: "Rome Fiumicino", city: "Rome", lat: 41.8003, lon: 12.2389),
        Airport(iata: "ZRH", name: "Zurich Airport", city: "Zurich", lat: 47.4582, lon: 8.5555),
        Airport(iata: "CPH", name: "Copenhagen Airport", city: "Copenhagen", lat: 55.6180, lon: 12.6508)
    ]

    static func loadAirports() -> [Airport] {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Airport].self, from: data),
              !decoded.isEmpty else {
            return fallbackAirports
        }
        return decoded.sorted { $0.iata < $1.iata }
    }
}

struct DestinationCalculatorContent: View {
    let currentCoordinate: CLLocationCoordinate2D?
    let speedMps: Double?
    @Binding var selectedAirport: Airport?
    @Binding var favoriteCodes: Set<String>

    @State private var airports: [Airport] = []
    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    showingPicker = true
                } label: {
                    HStack {
                        if let airport = selectedAirport {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(airport.iata) · \(airport.city)")
                                    .font(.subheadline.bold())
                                Text(airport.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("Select Destination Airport")
                                .font(.subheadline.bold())
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                if selectedAirport != nil {
                    Button(role: .destructive) {
                        selectedAirport = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let airport = selectedAirport, let current = currentCoordinate {
                let metrics = computeMetrics(from: current, to: airport.coordinate, speedMps: speedMps)

                HStack {
                    CalcMetricTile(
                        title: "Distance (NM)",
                        value: String(format: "%.0f NM", metrics.distanceNm)
                    )
                    CalcMetricTile(
                        title: "Distance (km)",
                        value: String(format: "%.0f km", metrics.distanceKm)
                    )
                }

                HStack {
                    CalcMetricTile(
                        title: "Bearing",
                        value: String(format: "%.0f°", metrics.bearingDegrees)
                    )
                    CalcMetricTile(
                        title: "Remaining Time",
                        value: metrics.remainingTimeText
                    )
                }
            } else if selectedAirport != nil {
                Text("Waiting for current GPS position to calculate distance and remaining time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if airports.isEmpty {
                airports = AirportStore.loadAirports()
            }
        }
        .sheet(isPresented: $showingPicker) {
            AirportPickerSheet(
                airports: airports,
                selectedAirport: $selectedAirport,
                favoriteCodes: $favoriteCodes
            )
        }
    }

    private struct FlightMetrics {
        let distanceNm: Double
        let distanceKm: Double
        let bearingDegrees: Double
        let remainingTimeText: String
    }

    private func computeMetrics(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        speedMps: Double?
    ) -> FlightMetrics {
        let startLoc = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let endLoc = CLLocation(latitude: end.latitude, longitude: end.longitude)
        let meters = startLoc.distance(from: endLoc)

        let distanceNm = meters / 1852.0
        let distanceKm = meters / 1000.0

        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let lon2 = end.longitude * .pi / 180
        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearingRad = atan2(y, x)
        let bearingDeg = (bearingRad * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)

        let remainingTimeText: String
        if let spd = speedMps, spd > 20.0 {
            let seconds = meters / spd
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            remainingTimeText = formatter.string(from: seconds) ?? "--"
        } else {
            remainingTimeText = "--"
        }

        return FlightMetrics(
            distanceNm: distanceNm,
            distanceKm: distanceKm,
            bearingDegrees: bearingDeg,
            remainingTimeText: remainingTimeText
        )
    }
}

private struct AirportPickerSheet: View {
    let airports: [Airport]
    @Binding var selectedAirport: Airport?
    @Binding var favoriteCodes: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredAirports: [Airport] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Airport]
        if query.isEmpty {
            base = airports
        } else {
            base = airports.filter { airport in
                airport.iata.lowercased().contains(query) ||
                airport.city.lowercased().contains(query) ||
                airport.name.lowercased().contains(query)
            }
        }
        return base.sorted { lhs, rhs in
            let lhsFav = favoriteCodes.contains(lhs.iata)
            let rhsFav = favoriteCodes.contains(rhs.iata)
            if lhsFav != rhsFav { return lhsFav }
            return lhs.iata < rhs.iata
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredAirports) { airport in
                let isFav = favoriteCodes.contains(airport.iata)
                HStack(spacing: 12) {
                    Button {
                        selectedAirport = airport
                        dismiss()
                    } label: {
                        HStack {
                            Text(airport.iata)
                                .font(.headline.monospaced())
                                .frame(width: 48, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(airport.city)
                                    .font(.body.bold())
                                Text(airport.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        if isFav {
                            favoriteCodes.remove(airport.iata)
                        } else {
                            favoriteCodes.insert(airport.iata)
                        }
                        FavoriteAirportsStore.saveCodes(favoriteCodes)
                    } label: {
                        Image(systemName: isFav ? "star.fill" : "star")
                            .foregroundStyle(isFav ? .yellow : .secondary)
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFav ? "Remove \(airport.iata) from favorites" : "Add \(airport.iata) to favorites")
                }
            }
            .navigationTitle("IATA Airports")
            .searchable(text: $searchText, prompt: "Search IATA code, city, or airport")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct CalcMetricTile: View {
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
