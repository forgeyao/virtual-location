import MapKit

@MainActor
protocol MapCoordinateResolving {
    func system(for coordinate: CLLocationCoordinate2D, countryCode: String?) async throws -> CoordinateSystem
}

/// MapKit does not expose its active mainland-China datum. Confirm it using
/// two distant, fixed landmarks rather than assuming every Chinese coordinate
/// is GCJ-02. Country lookup excludes HK, Macao, Taiwan and neighbouring states.
@MainActor
final class MapCoordinates: MapCoordinateResolving {
    private var calibration: Task<CoordinateSystem, Error>?
    private var expires = Date.distantPast

    func system(for coordinate: CLLocationCoordinate2D, countryCode: String? = nil) async throws -> CoordinateSystem {
        guard ChinaCoordinates.mayNeedConversion(coordinate) else { return .wgs84 }
        let country: String
        if let countryCode { country = countryCode }
        else {
            let geocoder = CLGeocoder()
            let places = try await withTaskCancellationHandler {
                try await geocoder.reverseGeocodeLocation(
                    CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            } onCancel: {
                Task { @MainActor in geocoder.cancelGeocode() }
            }
            guard let code = places.first?.isoCountryCode else { throw Failure.unconfirmed }
            country = code
        }
        guard country == "CN" else { return .wgs84 }
        try Task.checkCancellation()
        if calibration == nil || Date() >= expires {
            expires = Date().addingTimeInterval(300)
            calibration = Task { try await Self.calibrate() }
        }
        do { return try await calibration!.value }
        catch { calibration = nil; throw error }
    }

    private static func calibrate() async throws -> CoordinateSystem {
        // WGS84 landmark footprints (Wikidata Q223207 and Tiananmen gate).
        // Search POI centroids need not equal the footprint centre: accept a
        // 120 m neighbourhood, with at least 300 m separation from the other datum.
        let anchors: [(String, CLLocationCoordinate2D)] = [
            ("上海 东方明珠 广播电视塔", .init(latitude: 31.2416694, longitude: 121.4947167)),
            ("北京 天安门", .init(latitude: 39.9073541, longitude: 116.3912201))
        ]
        var detected: [CoordinateSystem] = []
        for (query, reference) in anchors {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: reference, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
            let response = try await MKLocalSearch(request: request).start()
            guard let result = classify(response.mapItems.map { $0.placemark.coordinate }, reference: reference) else {
                throw Failure.unconfirmed
            }
            detected.append(result)
        }
        guard detected.count == 2, detected[0] == detected[1] else { throw Failure.unconfirmed }
        return detected[0]
    }

    static func classify(_ candidates: [CLLocationCoordinate2D], reference: CLLocationCoordinate2D) -> CoordinateSystem? {
        func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        let shifted = ChinaCoordinates.toGCJ02(reference)
        let wgs = candidates.map { distance($0, reference) }.min() ?? .infinity
        let gcj = candidates.map { distance($0, shifted) }.min() ?? .infinity
        if wgs < 120 && gcj > 300 { return .wgs84 }
        if gcj < 120 && wgs > 300 { return .gcj02 }
        return nil
    }

    enum Failure: Error { case unconfirmed }
}
