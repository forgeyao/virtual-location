import Foundation
import CoreLocation

struct TargetCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    init(_ location: CLLocationCoordinate2D) {
        latitude = location.latitude
        longitude = location.longitude
    }

    init?(latitude: String, longitude: String) {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        self.latitude = lat
        self.longitude = lon
    }

    var location: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct SavedLocation: Codable {
    let coordinate: TargetCoordinate
    let coordinateSystem: CoordinateSystem
    let name: String
    let generatedName: Bool
    let isUserInput: Bool
    let mapCoordinate: TargetCoordinate?
    let legacyFavoriteID: UUID?

    var isValid: Bool {
        CLLocationCoordinate2DIsValid(coordinate.location)
            && (mapCoordinate.map { CLLocationCoordinate2DIsValid($0.location) } ?? true)
    }
}

enum RandomLocationRange: Int, CaseIterable {
    case fifty = 50, hundred = 100, oneHundredFifty = 150, twoHundred = 200

    // Uniform east/north offsets form a square in the local tangent plane.
    // A great-circle destination avoids longitude division at the poles and
    // wraps the antimeridian. At these short distances the spherical metre
    // approximation differs from the ellipsoid by less than one metre.
    func offset<R: RandomNumberGenerator>(from center: TargetCoordinate, using generator: inout R) -> TargetCoordinate {
        let halfSide = Double(rawValue) / 2
        return Self.destination(from: center,
                                east: Double.random(in: -halfSide...halfSide, using: &generator),
                                north: Double.random(in: -halfSide...halfSide, using: &generator))
    }

    static func destination(from center: TargetCoordinate, east: Double, north: Double) -> TargetCoordinate {
        let distance = hypot(east, north)
        guard distance > 0 else { return center }
        let angle = distance / 6_371_008.8
        let bearing = atan2(east, north)
        let latitude = center.latitude * .pi / 180
        let longitude = center.longitude * .pi / 180
        let sinLatitude = sin(latitude) * cos(angle) + cos(latitude) * sin(angle) * cos(bearing)
        let targetLatitude = asin(min(1, max(-1, sinLatitude)))
        let targetLongitude = longitude + atan2(sin(bearing) * sin(angle) * cos(latitude),
                                               cos(angle) - sin(latitude) * sin(targetLatitude))
        let degrees = targetLongitude * 180 / .pi
        let wrappedLongitude = (degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return TargetCoordinate(.init(latitude: targetLatitude * 180 / .pi, longitude: wrappedLongitude))
    }
}

enum CoordinateSystem: String, Codable, CaseIterable {
    case wgs84, gcj02, unresolved

    var title: String {
        switch self {
        case .wgs84: return "WGS84（GPS）"
        case .gcj02: return "GCJ-02（国内地图）"
        case .unresolved: return "请选择坐标系"
        }
    }

    func toWGS84(_ value: TargetCoordinate) -> TargetCoordinate? {
        switch self {
        case .wgs84: return value
        case .gcj02: return TargetCoordinate(ChinaCoordinates.toWGS84(value.location))
        case .unresolved: return nil
        }
    }
}

// GCJ-02 forward equations adapted from wandergis/coordtransform (MIT).
// See THIRD_PARTY_NOTICES.md. The inverse is solved iteratively to avoid the
// several-metre residual of a single subtraction. This envelope is only a
// fast rejection test; the map adapter separately checks the country.
enum ChinaCoordinates {
    static func mayNeedConversion(_ point: CLLocationCoordinate2D) -> Bool {
        (3.86...53.55).contains(point.latitude) && (73.66...135.05).contains(point.longitude)
    }

    static func toGCJ02(_ point: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard mayNeedConversion(point) else { return point }
        let x = point.longitude - 105, y = point.latitude - 35
        let pi = Double.pi, a = 6378245.0, e = 0.00669342162296594323
        let wave = (20 * sin(6 * x * pi) + 20 * sin(2 * x * pi)) * 2 / 3
        var lat = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x)) + wave
        lat += (20*sin(y*pi) + 40*sin(y*pi/3)) * 2/3
        lat += (160*sin(y*pi/12) + 320*sin(y*pi/30)) * 2/3
        var lon = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x)) + wave
        lon += (20*sin(x*pi) + 40*sin(x*pi/3)) * 2/3
        lon += (150*sin(x*pi/12) + 300*sin(x*pi/30)) * 2/3
        let radians = point.latitude * pi/180
        let magic = 1 - e * pow(sin(radians), 2), root = sqrt(magic)
        lat *= 180 / ((a * (1-e)) / (magic * root) * pi)
        lon *= 180 / (a / root * cos(radians) * pi)
        return .init(latitude: point.latitude + lat, longitude: point.longitude + lon)
    }

    static func toWGS84(_ point: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard mayNeedConversion(point) else { return point }
        var estimate = point
        for _ in 0..<10 {
            let projected = toGCJ02(estimate)
            let latError = projected.latitude - point.latitude
            let lonError = projected.longitude - point.longitude
            estimate.latitude -= latError
            estimate.longitude -= lonError
            if max(abs(latError), abs(lonError)) < 1e-10 { break }
        }
        return estimate
    }
}
