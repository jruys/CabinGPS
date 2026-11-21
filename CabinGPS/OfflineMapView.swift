import SwiftUI
import CoreLocation

struct CityPoint: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct OfflineMapView: View {
    let currentCoordinate: CLLocationCoordinate2D?
    let courseDegrees: Double?
    let trackCoordinates: [CLLocationCoordinate2D]
    let destinationAirport: Airport?
    var favoriteAirports: [Airport] = []
    var speedMps: Double? = nil
    var mapHeight: CGFloat = 210
    var showFullScreenButton: Bool = true
    var onDismissFullScreen: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    @State private var polygons: [[CLLocationCoordinate2D]] = []
    @State private var cities: [CityPoint] = []
    @State private var zoom: CGFloat = 5.0
    @State private var lastZoom: CGFloat = 5.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var followAircraft: Bool = true
    @State private var isPresentingFullScreen: Bool = false
    @State private var showFavoritesOnFullScreen: Bool = true

    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 80.0

    // Safe Mercator latitude bounds to avoid pole asymptotes
    private let minLat: Double = -85.0
    private let maxLat: Double = 85.0

    private var destinationGreen: Color {
        colorScheme == .dark
            ? Color(red: 0.32, green: 0.92, blue: 0.55)
            : Color(red: 0.04, green: 0.52, blue: 0.20)
    }

    private var seaFillColor: Color {
        colorScheme == .dark
            ? Color(red: 0.06, green: 0.16, blue: 0.20)
            : Color(red: 0.78, green: 0.90, blue: 0.93)
    }

    private var landFillColor: Color {
        colorScheme == .dark
            ? Color(red: 0.17, green: 0.20, blue: 0.23)
            : Color(red: 0.96, green: 0.95, blue: 0.91)
    }

    private var borderStrokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.32)
            : Color.black.opacity(0.35)
    }

    private var gridStrokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    private var fullScreenRouteSummary: (distanceKmText: String, remainingTimeText: String)? {
        guard let dest = destinationAirport, let current = currentCoordinate else { return nil }
        let startLoc = CLLocation(latitude: current.latitude, longitude: current.longitude)
        let endLoc = CLLocation(latitude: dest.coordinate.latitude, longitude: dest.coordinate.longitude)
        let meters = startLoc.distance(from: endLoc)
        let distText = String(format: "%.0f km", meters / 1000.0)

        let timeText: String
        if let spd = speedMps, spd > 20.0 {
            let seconds = meters / spd
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            timeText = formatter.string(from: seconds) ?? "--"
        } else {
            timeText = "--"
        }

        return (distText, timeText)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    // Sea / background
                    context.fill(
                        Path(CGRect(origin: .zero, size: canvasSize)),
                        with: .color(seaFillColor)
                    )

                    drawGrid(in: &context, size: canvasSize)

                    // Country fills & borders from world.geojson
                    for ring in polygons {
                        let points = ring.map { project($0, in: canvasSize) }
                        guard points.count > 2 else { continue }
                        var path = Path()
                        path.move(to: points[0])
                        for pt in points.dropFirst() {
                            path.addLine(to: pt)
                        }
                        path.closeSubpath()

                        context.fill(path, with: .color(landFillColor))
                        context.stroke(path, with: .color(borderStrokeColor), lineWidth: 1.0)
                    }

                    // Optional cities overlay if bundled
                    for city in cities {
                        let pt = project(city.coordinate, in: canvasSize)
                        guard pt.x >= -20, pt.x <= canvasSize.width + 20,
                              pt.y >= -20, pt.y <= canvasSize.height + 20 else { continue }

                        let dotRect = CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)
                        context.fill(Path(ellipseIn: dotRect), with: .color(Color.primary.opacity(0.75)))

                        if zoom >= 3.0 {
                            let text = Text(city.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.85))
                            context.draw(text, at: CGPoint(x: pt.x + 5, y: pt.y - 4), anchor: .bottomLeading)
                        }
                    }

                    // Full-screen-only favorite airports overlay
                    if !showFullScreenButton && showFavoritesOnFullScreen {
                        for fav in favoriteAirports where fav.iata != destinationAirport?.iata {
                            let favPt = project(fav.coordinate, in: canvasSize)
                            guard favPt.x >= -40, favPt.x <= canvasSize.width + 40,
                                  favPt.y >= -40, favPt.y <= canvasSize.height + 40 else { continue }

                            let dotRect = CGRect(x: favPt.x - 4, y: favPt.y - 4, width: 8, height: 8)
                            context.fill(Path(ellipseIn: dotRect), with: .color(.yellow))
                            context.stroke(Path(ellipseIn: dotRect), with: .color(borderStrokeColor), lineWidth: 1.2)

                            if zoom >= 2.0 {
                                let favLabel = Text(fav.iata)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.primary.opacity(0.9))
                                context.draw(
                                    favLabel,
                                    at: CGPoint(x: favPt.x + 6, y: favPt.y),
                                    anchor: .leading
                                )
                            }
                        }
                    }

                    // Dotted direct route line from current position to selected destination
                    if let current = currentCoordinate, let dest = destinationAirport {
                        let startPt = project(current, in: canvasSize)
                        let endPt = project(dest.coordinate, in: canvasSize)
                        var routePath = Path()
                        routePath.move(to: startPt)
                        routePath.addLine(to: endPt)
                        context.stroke(
                            routePath,
                            with: .color(destinationGreen),
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [1, 6])
                        )
                    }

                    // Flight breadcrumb trail
                    if trackCoordinates.count > 1 {
                        let trailPoints = trackCoordinates.map { project($0, in: canvasSize) }
                        var trailPath = Path()
                        trailPath.move(to: trailPoints[0])
                        for pt in trailPoints.dropFirst() {
                            trailPath.addLine(to: pt)
                        }
                        context.stroke(
                            trailPath,
                            with: .color(.orange),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                    }

                    // Selected destination marker & IATA label
                    if let dest = destinationAirport {
                        let destPt = project(dest.coordinate, in: canvasSize)
                        let outerRect = CGRect(x: destPt.x - 8, y: destPt.y - 8, width: 16, height: 16)
                        let innerRect = CGRect(x: destPt.x - 3.5, y: destPt.y - 3.5, width: 7, height: 7)

                        context.fill(Path(ellipseIn: outerRect), with: .color(destinationGreen.opacity(0.24)))
                        context.stroke(Path(ellipseIn: outerRect), with: .color(destinationGreen), lineWidth: 2)
                        context.fill(Path(ellipseIn: innerRect), with: .color(destinationGreen))

                        let label = Text(dest.iata)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(destinationGreen)
                        context.draw(
                            label,
                            at: CGPoint(x: destPt.x + 10, y: destPt.y),
                            anchor: .leading
                        )
                    }

                    // Current aircraft/phone position
                    if let coord = currentCoordinate {
                        let pt = project(coord, in: canvasSize)
                        let markerRect = CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)
                        context.fill(Path(ellipseIn: markerRect), with: .color(.red))
                        context.stroke(Path(ellipseIn: markerRect), with: .color(.white), lineWidth: 2)

                        if let course = courseDegrees {
                            let rad = (course - 90) * .pi / 180
                            let tip = CGPoint(x: pt.x + cos(rad) * 18, y: pt.y + sin(rad) * 18)
                            var headingLine = Path()
                            headingLine.move(to: pt)
                            headingLine.addLine(to: tip)
                            context.stroke(headingLine, with: .color(.red), lineWidth: 2)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            followAircraft = false
                            panOffset = CGSize(
                                width: lastPanOffset.width + value.translation.width,
                                height: lastPanOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastPanOffset = panOffset
                        }
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            zoom = min(max(lastZoom * scale, minZoom), maxZoom)
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                        }
                )

                // Top-left destination + full-screen distance & remaining time cluster
                if let dest = destinationAirport {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Dest: \(dest.iata)", systemImage: "airplane.arrival")
                            .font(.caption.bold())
                            .foregroundStyle(destinationGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                colorScheme == .dark
                                    ? Color(red: 0.08, green: 0.24, blue: 0.14).opacity(0.92)
                                    : Color(red: 0.88, green: 0.98, blue: 0.91).opacity(0.95),
                                in: Capsule()
                            )

                        if !showFullScreenButton, let summary = fullScreenRouteSummary {
                            HStack(spacing: 10) {
                                Label(summary.distanceKmText, systemImage: "ruler")
                                Label(summary.remainingTimeText, systemImage: "clock")
                            }
                            .font(.caption.monospacedDigit().bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }

                // Bottom-left fallback notice when GeoJSON isn't loaded
                if polygons.isEmpty {
                    Text("Add world.geojson to target to render borders")
                        .font(.caption2)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }

                // Bottom-right floating controls
                mapControlsCluster
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(height: mapHeight)
        .onAppear {
            if polygons.isEmpty {
                polygons = GeoJSONLoader.loadPolygons()
            }
            if cities.isEmpty {
                cities = GeoJSONLoader.loadCities()
            }
        }
        .fullScreenCover(isPresented: $isPresentingFullScreen) {
            FullScreenMapContainer(
                currentCoordinate: currentCoordinate,
                courseDegrees: courseDegrees,
                trackCoordinates: trackCoordinates,
                destinationAirport: destinationAirport,
                favoriteAirports: favoriteAirports,
                speedMps: speedMps
            )
        }
    }

    private var mapControlsCluster: some View {
        VStack(spacing: 6) {
            // Full-screen-only show/hide favorites toggle
            if !showFullScreenButton {
                Button {
                    showFavoritesOnFullScreen.toggle()
                } label: {
                    Image(systemName: showFavoritesOnFullScreen ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(showFavoritesOnFullScreen ? .yellow : .primary)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showFavoritesOnFullScreen ? "Hide favorite airports" : "Show favorite airports")
            }

            Button {
                centerOnCurrentLocation()
            } label: {
                Image(systemName: followAircraft ? "location.fill" : "scope")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(currentCoordinate == nil)
            .opacity(currentCoordinate == nil ? 0.45 : 1.0)
            .accessibilityLabel("Center on current location")

            if showFullScreenButton {
                Button {
                    isPresentingFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Full screen map")
            } else if let onDismissFullScreen {
                Button {
                    onDismissFullScreen()
                } label: {
                    Text("Done")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func centerOnCurrentLocation() {
        followAircraft = true
        panOffset = .zero
        lastPanOffset = .zero
    }

    // Equal-aspect conformal Mercator projection
    private func mercatorRadians(_ coord: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let clampedLat = min(max(coord.latitude, minLat), maxLat)
        let lonRad = coord.longitude * .pi / 180.0
        let latRad = clampedLat * .pi / 180.0
        let mercY = log(tan(.pi / 4.0 + latRad / 2.0))
        return (lonRad, -mercY)
    }

    private func project(_ coord: CLLocationCoordinate2D, in size: CGSize) -> CGPoint {
        let pixelsPerRadian = max(size.width, size.height) / (2.0 * .pi) * Double(zoom)
        let pt = mercatorRadians(coord)

        let anchor = (followAircraft ? currentCoordinate : nil)
            ?? CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.9041)
        let anchorMerc = mercatorRadians(anchor)

        let dx = (pt.x - anchorMerc.x) * pixelsPerRadian
        let dy = (pt.y - anchorMerc.y) * pixelsPerRadian

        let x = (size.width / 2.0) + dx + panOffset.width
        let y = (size.height / 2.0) + dy + panOffset.height
        return CGPoint(x: x, y: y)
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for lon in stride(from: -180.0, through: 180.0, by: 15.0) {
            let p1 = project(CLLocationCoordinate2D(latitude: minLat, longitude: lon), in: size)
            let p2 = project(CLLocationCoordinate2D(latitude: maxLat, longitude: lon), in: size)
            var line = Path()
            line.move(to: p1)
            line.addLine(to: p2)
            context.stroke(line, with: .color(gridStrokeColor), lineWidth: 1)
        }
        for lat in stride(from: -80.0, through: 80.0, by: 15.0) {
            let p1 = project(CLLocationCoordinate2D(latitude: lat, longitude: -180.0), in: size)
            let p2 = project(CLLocationCoordinate2D(latitude: lat, longitude: 180.0), in: size)
            var line = Path()
            line.move(to: p1)
            line.addLine(to: p2)
            context.stroke(line, with: .color(gridStrokeColor), lineWidth: 1)
        }
    }
}

private struct FullScreenMapContainer: View {
    let currentCoordinate: CLLocationCoordinate2D?
    let courseDegrees: Double?
    let trackCoordinates: [CLLocationCoordinate2D]
    let destinationAirport: Airport?
    let favoriteAirports: [Airport]
    let speedMps: Double?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            OfflineMapView(
                currentCoordinate: currentCoordinate,
                courseDegrees: courseDegrees,
                trackCoordinates: trackCoordinates,
                destinationAirport: destinationAirport,
                favoriteAirports: favoriteAirports,
                speedMps: speedMps,
                mapHeight: max(geo.size.height - 24, 300),
                showFullScreenButton: false,
                onDismissFullScreen: { dismiss() }
            )
            .padding(12)
        }
        .background(Color(.systemBackground))
    }
}

private enum GeoJSONLoader {
    static func loadPolygons() -> [[CLLocationCoordinate2D]] {
        guard let url = Bundle.main.url(forResource: "world", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [[CLLocationCoordinate2D]] = []

        func extractGeometry(_ geom: [String: Any]) {
            guard let type = geom["type"] as? String else { return }
            if type == "Polygon", let rings = geom["coordinates"] as? [[[Double]]] {
                for ring in rings {
                    results.append(coordsFromRing(ring))
                }
            } else if type == "MultiPolygon", let polys = geom["coordinates"] as? [[[[Double]]]] {
                for poly in polys {
                    for ring in poly {
                        results.append(coordsFromRing(ring))
                    }
                }
            }
        }

        if let features = json["features"] as? [[String: Any]] {
            for feature in features {
                if let geom = feature["geometry"] as? [String: Any] {
                    extractGeometry(geom)
                }
            }
        } else if let geometries = json["geometries"] as? [[String: Any]] {
            for geom in geometries {
                extractGeometry(geom)
            }
        } else {
            extractGeometry(json)
        }

        return results
    }

    static func loadCities() -> [CityPoint] {
        guard let url = Bundle.main.url(forResource: "europe_cities", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            return []
        }

        return features.compactMap { feature in
            guard let geom = feature["geometry"] as? [String: Any],
                  (geom["type"] as? String) == "Point",
                  let coords = geom["coordinates"] as? [Double],
                  coords.count >= 2 else {
                return nil
            }
            let props = feature["properties"] as? [String: Any]
            let name = (props?["nameascii"] as? String)
                ?? (props?["name"] as? String)
                ?? ""
            guard !name.isEmpty else { return nil }
            return CityPoint(
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0])
            )
        }
    }

    private static func coordsFromRing(_ ring: [[Double]]) -> [CLLocationCoordinate2D] {
        ring.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }
}
