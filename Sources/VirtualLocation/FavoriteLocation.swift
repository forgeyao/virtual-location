import Foundation

struct FavoriteLocation: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    var coordinateSystem: CoordinateSystem? = nil

    func matches(_ coordinate: TargetCoordinate, system: CoordinateSystem = .wgs84) -> Bool {
        let raw = TargetCoordinate(.init(latitude: latitude, longitude: longitude))
        let savedSystem = coordinateSystem ?? (ChinaCoordinates.mayNeedConversion(raw.location) ? .unresolved : .wgs84)
        guard let saved = savedSystem.toWGS84(raw), let selected = system.toWGS84(coordinate) else { return false }
        return abs(saved.latitude - selected.latitude) < 0.0000001 && abs(saved.longitude - selected.longitude) < 0.0000001
    }

    var coordinateText: String { String(format: "%.5f, %.5f", latitude, longitude) }
}

struct FavoriteStore {
    static let limit = 5
    let url: URL

    func load() throws -> [FavoriteLocation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let locations: [FavoriteLocation]
        if let legacy = try? decoder.decode([FavoriteLocation].self, from: data) {
            // The original array was saved oldest first. Preserve its history.
            locations = Array(legacy.reversed())
        } else {
            let archive = try decoder.decode(Archive.self, from: data)
            guard [2, 3].contains(archive.version) else { throw CocoaError(.fileReadCorruptFile) }
            locations = archive.locations
        }
        try validate(locations)
        return locations
    }

    func save(_ locations: [FavoriteLocation]) throws {
        try validate(locations)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Archive(version: 3, locations: locations)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validate(_ locations: [FavoriteLocation]) throws {
        guard locations.count <= Self.limit, Set(locations.map(\.id)).count == locations.count,
              locations.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.latitude.isFinite && $0.longitude.isFinite
                  && $0.coordinateSystem != .unresolved
                  && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private struct Archive: Codable {
        let version: Int
        let locations: [FavoriteLocation]
    }
}
