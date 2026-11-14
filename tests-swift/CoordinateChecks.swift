import Foundation
import MapKit
import Combine
import SwiftUI

@main
struct CoordinateChecks {
    @MainActor static func main() async {
        precondition(TargetCoordinate(latitude: "-90", longitude: "180") != nil)
        precondition(TargetCoordinate(latitude: " -33.8568 ", longitude: "151.2153")?.latitude == -33.8568)
        for pair in [("nan", "1"), ("90.01", "1"), ("0", "-180.01"), ("", "0"), ("inf", "1")] {
            precondition(TargetCoordinate(latitude: pair.0, longitude: pair.1) == nil)
        }
        print("7 coordinate validation checks passed")
        let model = AppModel(preview: true)
        model.receive(["stage": "recovery_required", "sessionId": "still-connected"])
        precondition(model.connected) // Keep Stop available after an uncertain write.
        model.receive(["stage": "recovery_required", "sessionId": NSNull()])
        precondition(!model.connected)
        print("2 recovery-state UI checks passed")
        await automaticConnectionChecks()
        favoriteChecks()
        preferencesChecks()
        await searchClearChecks()
        await mapSelectionChecks()
        await coordinateSystemChecks()
        await defaultCoordinateSystemChecks()
        await randomLocationChecks()
        statusPresentationChecks()
    }

    @MainActor static func statusPresentationChecks() {
        let backend = TestDeviceBackend()
        let preferences = AppPreferences()
        let model = AppModel(preview: true, backend: backend, preferences: preferences)
        for state in ["disconnected", "discovering", "trust_and_developer_mode", "checking_image", "preparing_image",
                      "mounting_image", "opening_tunnel", "opening_location_service", "recovering", "ready",
                      "simulating", "stopping", "retrying"] {
            model.receive(["stage": state])
            precondition(!model.statusIsError && model.statusText == model.statusTitle)
        }
        model.receive(["event": "connectionLost", "message": "连接已中断，手机定位状态待确认"])
        precondition(model.statusIsError && model.statusText == "连接已中断，手机定位状态待确认")
        precondition(!model.connected && !model.canApply)
        preferences.language = .english
        precondition(model.statusText == "Connection lost. Check the location on your phone.")
        model.error = nil
        precondition(model.statusIsError && model.statusText == "Location status is uncertain. Check the location in Maps on your phone.")
        backend.onExit?()
        precondition(model.statusIsError && model.statusText == preferences.text("后台已退出。若此前正在模拟，请在手机确认位置状态。"))
        model.error = "设备尚未就绪"
        precondition(model.statusText == "The device is not ready.")
        model.error = nil
        model.receive(["stage": "ready"])
        precondition(!model.statusIsError && model.statusText == "iPhone Connected")
        precondition(backend.commands.isEmpty)
        print("Status presentation checks passed: ordinary preparation/ready/sent states, full connection-loss error, English localization, uncertain location without an error, backend exit, operation error and recovery; no device access")
    }

    @MainActor static func randomLocationChecks() async {
        let center = TargetCoordinate(.init(latitude: 23.0061674, longitude: 113.343134))
        var generator = SeededRandom(seed: 42)
        for range in RandomLocationRange.allCases {
            let half = Double(range.rawValue) / 2
            var eastTotal = 0.0, northTotal = 0.0, quadrants = [0, 0, 0, 0]
            var west = 0.0, east = 0.0, south = 0.0, north = 0.0
            for _ in 0..<3000 {
                let sample = range.offset(from: center, using: &generator)
                let displacement = localOffset(sample, from: center)
                precondition(abs(displacement.east) <= half + 0.01 && abs(displacement.north) <= half + 0.01)
                eastTotal += displacement.east; northTotal += displacement.north
                quadrants[(displacement.east < 0 ? 0 : 1) + (displacement.north < 0 ? 0 : 2)] += 1
                west = min(west, displacement.east); east = max(east, displacement.east)
                south = min(south, displacement.north); north = max(north, displacement.north)
            }
            precondition(abs(eastTotal / 3000) < half * 0.05 && abs(northTotal / 3000) < half * 0.05)
            precondition(quadrants.allSatisfy { $0 > 600 })
            precondition(west < -half * 0.95 && east > half * 0.95 && south < -half * 0.95 && north > half * 0.95)
        }
        for location in [CLLocationCoordinate2D(latitude: 0, longitude: 180), .init(latitude: 0, longitude: -180),
                         .init(latitude: 89.99999, longitude: 150), .init(latitude: 90, longitude: 0),
                         .init(latitude: -90, longitude: -170), .init(latitude: -33.8568, longitude: 151.2153)] {
            let origin = TargetCoordinate(location)
            for e in [-100.0, 0, 100] {
                for n in [-100.0, 0, 100] {
                    let sample = RandomLocationRange.destination(from: origin, east: e, north: n)
                    precondition(CLLocationCoordinate2DIsValid(sample.location))
                    let distance = CLLocation(latitude: location.latitude, longitude: location.longitude)
                        .distance(from: CLLocation(latitude: sample.latitude, longitude: sample.longitude))
                    precondition(abs(distance - hypot(e, n)) < 1)
                }
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = TestDeviceBackend()
        let model = AppModel(preview: true, backend: backend, favoritesURL: directory.appendingPathComponent("favorites.json"),
                             mapCoordinates: FixedMapCoordinates(.gcj02))
        precondition(!model.preferences.randomLocationEnabled && model.preferences.randomLocationRange == .fifty)
        model.apply()
        precondition(backend.commands.isEmpty) // Invalid/disconnected cannot send.
        backend.deviceIDs = ["phone"]
        await model.checkForDevice()
        model.select(.init(latitude: 23.003558, longitude: 113.3485861), name: "Center", system: .gcj02)
        while model.point == nil { await Task.yield() }
        precondition(model.addFavorite(name: "Center"))
        let rawLatitude = model.latitude, rawLongitude = model.longitude
        let selected = model.point!, favorites = model.favorites, converted = model.deviceCoordinate!
        model.apply()
        while model.busy { await Task.yield() }
        precondition(backend.locations.last == converted && model.lastRandomizedCoordinate == nil)
        let beforeToggle = backend.commands.count
        model.preferences.randomLocationEnabled = true
        model.preferences.randomLocationRange = .hundred
        await Task.yield()
        precondition(backend.commands.count == beforeToggle) // Toggle never sends or starts a timer.
        for range in RandomLocationRange.allCases {
            model.preferences.randomLocationRange = range
            var payloads: [TargetCoordinate] = []
            for _ in 0..<8 {
                model.apply()
                while model.busy { await Task.yield() }
                let sent = backend.locations.last!
                let displacement = localOffset(sent, from: converted)
                precondition(abs(displacement.east) <= Double(range.rawValue) / 2 + 0.01)
                precondition(abs(displacement.north) <= Double(range.rawValue) / 2 + 0.01)
                precondition(model.lastRandomizedCoordinate == sent)
                payloads.append(sent)
            }
            precondition(Set(payloads.map { "\($0.latitude),\($0.longitude)" }).count == payloads.count)
        }
        precondition(model.latitude == rawLatitude && model.longitude == rawLongitude && model.favorites == favorites)
        precondition(model.point!.latitude == selected.latitude && model.point!.longitude == selected.longitude)
        precondition(model.deviceCoordinate == converted) // No accumulated drift or double datum conversion.
        let lastSuccessful = model.lastRandomizedCoordinate
        backend.failSetLocation = true
        model.apply()
        while model.busy { await Task.yield() }
        precondition(model.error != nil && model.lastRandomizedCoordinate == lastSuccessful)
        backend.failSetLocation = false
        model.preferences.randomLocationEnabled = false
        model.apply()
        while model.busy { await Task.yield() }
        precondition(backend.locations.last == converted && model.lastRandomizedCoordinate == nil)
        model.select(center.location, name: "WGS", system: .wgs84)
        model.preferences.randomLocationEnabled = true
        model.apply()
        while model.busy { await Task.yield() }
        let wgsOffset = localOffset(backend.locations.last!, from: center)
        let halfSide = Double(model.preferences.randomLocationRange.rawValue) / 2
        precondition(abs(wgsOffset.east) <= halfSide + 0.01 && abs(wgsOffset.north) <= halfSide + 0.01)
        model.select(.init(latitude: 23, longitude: 113), name: "Unknown", system: .unresolved)
        let count = backend.commands.count
        model.apply()
        await Task.yield()
        precondition(backend.commands.count == count) // Random mode cannot bypass datum confirmation.
        await model.quit()
        print("Random location checks passed: disabled default, 30/50/100/200 metre squares, uniform coverage, poles/antimeridian, fresh per-click WGS84/GCJ payloads, no accumulated drift, source/favorite preservation, failures and unresolved/disconnected guards; fake backend only")
    }

    // Independent short-distance projection for checking square bounds.
    static func localOffset(_ point: TargetCoordinate, from center: TargetCoordinate) -> (east: Double, north: Double) {
        let radians = Double.pi / 180
        return ((point.longitude - center.longitude) * radians * 6_371_008.8 * cos(center.latitude * radians),
                (point.latitude - center.latitude) * radians * 6_371_008.8)
    }

    @MainActor static func mapSelectionChecks() async {
        let backend = TestDeviceBackend()
        let model = AppModel(preview: true, backend: backend, mapCoordinates: FixedMapCoordinates(.wgs84))
        let center = CLLocationCoordinate2D(latitude: -33.8568, longitude: 151.2153)
        model.position = .camera(MapCamera(centerCoordinate: center, distance: 80, heading: 137, pitch: 55))
        var cameraUpdates = 0
        let observer = model.$position.dropFirst().sink { _ in cameraUpdates += 1 }
        defer { observer.cancel() }

        model.selectMapPoint(.init(latitude: -33.8569, longitude: 151.2154))
        model.selectMapPoint(.init(latitude: -33.8570, longitude: 151.2155))
        precondition(model.latitude == "-33.8570000" && model.longitude == "151.2155000")
        precondition(model.point?.latitude == -33.8570 && model.placeName == "地图选点")
        precondition(cameraUpdates == 0) // A map tap must not publish any camera change.
        let camera = model.position.camera!
        precondition(camera.distance == 80 && camera.heading == 137 && camera.pitch == 55)
        precondition(camera.centerCoordinate.latitude == center.latitude && camera.centerCoordinate.longitude == center.longitude)

        model.returnToSelection()
        precondition(cameraUpdates == 1 && model.position.region?.center.latitude == -33.8570)
        model.select(.init(latitude: 31.24, longitude: 121.49), name: "Search or favorite")
        await Task.yield()
        precondition(cameraUpdates == 2 && model.position.region?.center.latitude == 31.24)
        precondition(backend.commands.isEmpty)
        print("Map selection checks passed: repeated taps preserve zoom, center, heading and pitch; explicit recenter and place selection still move camera")
    }

    @MainActor static func coordinateSystemChecks() async {
        let raw = CLLocationCoordinate2D(latitude: 23.0035580, longitude: 113.3485861)
        let expected = CLLocationCoordinate2D(latitude: 23.006167400721598, longitude: 113.34313398918722)
        let converted = ChinaCoordinates.toWGS84(raw)
        precondition(abs(converted.latitude - expected.latitude) < 1e-10)
        precondition(abs(converted.longitude - expected.longitude) < 1e-10)
        for pair in [(23.0061674, 113.343134), (39.9073541, 116.3912201), (31.2419, 121.49526), (30.66, 104.06)] {
            let wgs = CLLocationCoordinate2D(latitude: pair.0, longitude: pair.1)
            let back = ChinaCoordinates.toWGS84(ChinaCoordinates.toGCJ02(wgs))
            precondition(abs(back.latitude - wgs.latitude) < 1e-9 && abs(back.longitude - wgs.longitude) < 1e-9)
        }
        let sydney = CLLocationCoordinate2D(latitude: -33.8568, longitude: 151.2153)
        precondition(ChinaCoordinates.toWGS84(sydney).latitude == sydney.latitude)
        precondition(ChinaCoordinates.toGCJ02(sydney).longitude == sydney.longitude)
        let anchor = CLLocationCoordinate2D(latitude: 31.2419, longitude: 121.49526)
        precondition(MapCoordinates.classify([anchor], reference: anchor) == .wgs84)
        precondition(MapCoordinates.classify([ChinaCoordinates.toGCJ02(anchor)], reference: anchor) == .gcj02)
        precondition(MapCoordinates.classify([anchor, ChinaCoordinates.toGCJ02(anchor)], reference: anchor) == nil)
        precondition(MapCoordinates.classify([sydney], reference: anchor) == nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("favorites.json")
        let backend = TestDeviceBackend()
        let resolver = FixedMapCoordinates(.gcj02)
        let model = AppModel(preview: true, backend: backend, favoritesURL: url, mapCoordinates: resolver)
        backend.deviceIDs = ["phone"]
        await model.checkForDevice()
        model.position = .camera(MapCamera(centerCoordinate: raw, distance: 80, heading: 137, pitch: 55))
        var cameraUpdates = 0
        let cameraObserver = model.$position.dropFirst().sink { _ in cameraUpdates += 1 }
        model.selectMapPoint(raw)
        precondition(!model.canApply && model.coordinateSystem == .unresolved)
        model.returnToSelection() // Recenter must not cancel the in-flight map datum resolution.
        await Task.yield()
        precondition(model.coordinateSystem == .gcj02 && model.canApply)
        precondition(cameraUpdates == 0 && model.position.camera?.distance == 80)
        cameraObserver.cancel() // Async mainland datum confirmation also preserves the camera.
        precondition(model.latitude == "23.0035580" && model.point?.longitude == raw.longitude)
        model.apply()
        await Task.yield()
        precondition(abs(backend.locations.last!.latitude - expected.latitude) < 1e-10)
        precondition(abs(backend.locations.last!.longitude - expected.longitude) < 1e-10)
        precondition(model.addFavorite(name: "Guangzhou"))
        let saved = try! FavoriteStore(url: url).load().first!
        precondition(saved.coordinateSystem == .gcj02)
        model.selectFavorite(saved)
        await Task.yield()
        model.apply()
        await Task.yield()
        precondition(abs(backend.locations.last!.longitude - expected.longitude) < 1e-10) // No second conversion.
        precondition(abs(model.point!.longitude - raw.longitude) < 1e-8) // Display returns to the same map point.
        model.select(expected, name: "GPS", system: .wgs84)
        await Task.yield()
        model.apply()
        await Task.yield()
        precondition(abs(backend.locations.last!.longitude - expected.longitude) < 1e-7) // Manual GPS unchanged.
        precondition(model.currentFavorite?.id == saved.id) // Same physical point, different input datum.

        let legacy = FavoriteLocation(id: UUID(), name: "Old China favorite", latitude: raw.latitude, longitude: raw.longitude)
        try! FavoriteStore(url: url).save([legacy])
        let legacyModel = AppModel(preview: true, backend: TestDeviceBackend(), favoritesURL: url, mapCoordinates: resolver)
        legacyModel.selectFavorite(legacy)
        legacyModel.returnToSelection() // Nor discard the old-favorite confirmation context.
        legacyModel.setInputCoordinateSystem(.gcj02)
        precondition((try! FavoriteStore(url: url).load()).first?.coordinateSystem == .gcj02)
        precondition(legacyModel.currentFavorite?.id == legacy.id) // Confirmation is persisted once.
        model.selectFavorite(legacy)
        precondition(model.coordinateSystem == .unresolved && !model.canApply && model.deviceCoordinate == nil)
        model.setInputCoordinateSystem(.gcj02)
        precondition(model.canApply)
        model.selectMapPoint(raw)
        model.preferences.coordinateSystem = .wgs84
        model.latitude = "24" // A stale detection may not relabel newly edited input.
        await Task.yield()
        precondition(model.coordinateSystem == .wgs84 && model.deviceCoordinate?.latitude == 24)
        resolver.fail = true
        model.selectMapPoint(raw)
        await Task.yield()
        precondition(!model.canApply && !model.coordinateMessage.isEmpty)
        model.select(sydney, name: "Sydney")
        model.apply()
        await Task.yield()
        precondition(backend.locations.last!.latitude == sydney.latitude && model.coordinateSystem == .wgs84)

        let wgsMap = AppModel(preview: true, backend: TestDeviceBackend(), mapCoordinates: FixedMapCoordinates(.wgs84))
        wgsMap.selectMapPoint(expected)
        await Task.yield()
        precondition(wgsMap.coordinateSystem == .wgs84)
        precondition(abs(wgsMap.deviceCoordinate!.longitude - expected.longitude) < 1e-7)
        let searchItem = MKMapItem(placemark: MKPlacemark(coordinate: raw))
        model.selectSearchResult(searchItem)
        resolver.fail = false
        await Task.yield()
        precondition(model.coordinateSystem == .gcj02 && abs(model.deviceCoordinate!.longitude - expected.longitude) < 1e-9)

        let actualResolver = MapCoordinates()
        let hongKong = try! await actualResolver.system(for: .init(latitude: 22.3, longitude: 114.2), countryCode: "HK")
        let taiwan = try! await actualResolver.system(for: .init(latitude: 25, longitude: 121.5), countryCode: "TW")
        precondition(hongKong == .wgs84 && taiwan == .wgs84)
        print("Coordinate-system checks passed: Guangzhou device payload, iterative inverse, map datum classification, GPS unchanged, favorite roundtrip, legacy blocking, stale responses, failure blocking, HK/Taiwan and Sydney")
    }

    @MainActor static func preferencesChecks() {
        precondition(AppPreferences.languageForLaunch(arguments: ["VirtualLocation", "--preview", "--ui-smoke"]) == .chinese)
        precondition(AppPreferences.languageForLaunch(arguments: ["VirtualLocation", "--preview", "--ui-smoke", "--language", "en"]) == .english)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")
        let preferences = AppPreferences(url: url)
        precondition(preferences.appearance == .system && preferences.language == .chinese && preferences.coordinateSystem == .gcj02)
        precondition(!preferences.requiresRelaunch)
        preferences.appearance = .dark
        preferences.language = .english
        preferences.randomLocationEnabled = true
        preferences.randomLocationRange = .twoHundred
        precondition(preferences.requiresRelaunch)
        let loaded = AppPreferences(url: url)
        precondition(loaded.appearance == .dark && loaded.language == .english)
        precondition(!loaded.requiresRelaunch)
        precondition(loaded.text("坐标") == "Coordinates" && loaded.text("修改定位") == "Change Location")
        precondition(loaded.format("位置 %d", 3) == "Location 3")
        loaded.appearance = .light
        precondition(AppPreferences(url: url).appearance == .light)
        loaded.appearance = .system
        loaded.language = .chinese
        precondition(loaded.requiresRelaunch)
        precondition(AppPreferences(url: url).appearance == .system && AppPreferences(url: url).language == .chinese)
        precondition(loaded.appearance.appearance == nil && loaded.text("坐标") == "坐标")
        let model = AppModel(preview: true, preferences: loaded)
        precondition(model.preferences.randomLocationEnabled && model.preferences.randomLocationRange == .twoHundred)
        model.preferences.randomLocationEnabled = false
        let reloaded = AppPreferences(url: url)
        precondition(!reloaded.randomLocationEnabled && reloaded.randomLocationRange == .twoHundred)
        model.state = "ready"
        model.appendLog("已发送设置请求")
        loaded.language = .english
        precondition(model.statusTitle == "iPhone Connected" && model.localizedLog.last!.hasSuffix("Location request sent"))
        model.select(.init(latitude: 1, longitude: 2), name: "设置")
        precondition(model.displayPlaceName == "设置") // User-authored names aren't localization keys.
        model.select(.init(latitude: 1, longitude: 2), name: "地图选点", generatedName: true)
        precondition(model.displayPlaceName == "Map selection")
        loaded.language = .chinese
        precondition(model.statusTitle == "手机已连接" && model.localizedLog.last!.hasSuffix("已发送设置请求"))
        print("Preferences checks passed: defaults, persistent appearance/language, system appearance, live status/log translations")
    }

    @MainActor static func defaultCoordinateSystemChecks() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("preferences.json")
        try! Data(#"{"appearance":"dark","language":"en"}"#.utf8).write(to: url)
        let preferences = AppPreferences(url: url)
        precondition(preferences.coordinateSystem == .gcj02 && preferences.appearance == .dark && preferences.language == .english)
        precondition(!preferences.randomLocationEnabled && preferences.randomLocationRange == .fifty)
        let backend = TestDeviceBackend()
        let model = AppModel(preview: true, backend: backend, favoritesURL: directory.appendingPathComponent("favorites.json"),
                             preferences: preferences, mapCoordinates: FixedMapCoordinates(.gcj02))
        precondition(model.coordinateSystem == .gcj02)
        model.latitude = "23.0035580"; model.longitude = "113.3485861"
        precondition(abs(model.deviceCoordinate!.longitude - 113.3431339892) < 1e-9)
        preferences.coordinateSystem = .wgs84
        precondition(model.coordinateSystem == .wgs84 && model.deviceCoordinate!.longitude == 113.3485861)
        precondition(AppPreferences(url: url).coordinateSystem == .wgs84)
        precondition(AppModel(preview: true, backend: TestDeviceBackend(), preferences: AppPreferences(url: url)).coordinateSystem == .wgs84)

        model.selectMapPoint(.init(latitude: 23.003558, longitude: 113.3485861))
        await Task.yield()
        precondition(model.coordinateSystem == .gcj02)
        preferences.coordinateSystem = .gcj02
        preferences.coordinateSystem = .wgs84
        precondition(model.coordinateSystem == .gcj02) // The default does not relabel a known map source.
        model.select(.init(latitude: 23.0061674, longitude: 113.343134), name: "GPS favorite", system: .wgs84)
        precondition(model.addFavorite(name: "GPS favorite"))
        let favorite = model.favorites.first!
        preferences.coordinateSystem = .gcj02
        model.selectFavorite(favorite)
        precondition(model.coordinateSystem == .wgs84 && model.deviceCoordinate!.longitude == favorite.longitude)
        model.latitude = "23.0035580"; model.longitude = "113.3485861"
        precondition(model.coordinateSystem == .gcj02) // Actual typing adopts the configured input datum.
        model.locateInput()
        preferences.coordinateSystem = .wgs84
        precondition(model.coordinateSystem == .wgs84)
        precondition(backend.commands.isEmpty)
        print("Default coordinate checks passed: GCJ-02 default, older preference compatibility, persistence, live typed-input changes, map/favorite provenance preserved, no device writes")
    }

    @MainActor static func searchClearChecks() async {
        let model = AppModel(preview: true, backend: TestDeviceBackend())
        model.query = "Sydney"
        model.results = [MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: -33.8568, longitude: 151.2153)))]
        model.searching = true
        model.searchMessage = "stale message"
        model.clearSearch()
        try? await Task.sleep(for: .milliseconds(450))
        precondition(model.query.isEmpty && model.results.isEmpty && model.suggestions.results.isEmpty)
        precondition(!model.searching && model.searchMessage.isEmpty)
        model.query = "London"
        model.dismissSearchResults()
        precondition(model.query == "London" && model.results.isEmpty && model.suggestions.results.isEmpty)
        await model.quit()
        print("Search clearing checks passed: cancels pending suggestions, clears text/results/progress, dismiss preserves query")
    }

    @MainActor static func favoriteChecks() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("favorites.json")
        let backend = TestDeviceBackend()
        let model = AppModel(preview: true, backend: backend, favoritesURL: url)
        precondition(!model.addFavorite(name: "Invalid coordinate"))
        for index in 0..<5 {
            model.select(.init(latitude: Double(index), longitude: Double(index + 10)), name: "Place \(index)")
            precondition(model.addFavorite(name: "Place \(index)"))
        }
        let original = model.favorites
        precondition(original.map(\.name) == ["Place 4", "Place 3", "Place 2", "Place 1", "Place 0"])
        precondition(model.addFavorite(name: "Duplicate"))
        precondition(model.favorites == original) // Repeated saves don't use another slot.
        model.select(.init(latitude: 20, longitude: 30), name: "Sixth")
        precondition(!model.addFavorite(name: "Sixth") && model.favorites.count == 5)
        precondition((try! FavoriteStore(url: url).load()) == original) // No replacement without confirmation.

        let reloaded = AppModel(preview: true, backend: TestDeviceBackend(), favoritesURL: url)
        precondition(reloaded.favorites == original)
        model.selectFavorite(original[0])
        precondition(model.latitude == "4.0000000" && model.longitude == "14.0000000")
        precondition(model.placeName == original[0].name && model.currentFavorite == original[0])
        model.returnToSelection()
        precondition(model.placeName == original[0].name)
        model.removeFavorite(original[0])
        precondition(model.favorites.count == 4 && model.currentFavorite == nil)
        precondition((try! FavoriteStore(url: url).load()) == model.favorites)
        let renamed = model.favorites[0]
        let idsBeforeRename = model.favorites.map(\.id)
        model.selectFavorite(renamed)
        precondition(!model.renameFavorite(renamed, name: "   "))
        precondition(model.renameFavorite(renamed, name: "  Home  "))
        precondition(model.favorites.map(\.id) == idsBeforeRename && model.favorites[0].name == "Home")
        precondition(model.favorites[0].latitude == renamed.latitude && model.favorites[0].longitude == renamed.longitude)
        precondition(model.placeName == "Home" && (try! FavoriteStore(url: url).load()) == model.favorites)
        model.selectFavorite(original[0])
        precondition(model.addFavorite(name: "New place") && model.favorites.count == 5)
        let beforeReplacement = model.favorites
        model.select(.init(latitude: 20, longitude: 30), name: "Sixth")
        precondition(model.addFavorite(name: "Sixth", replacingOldest: true))
        precondition(model.favorites.count == 5 && model.favorites.first?.name == "Sixth")
        precondition(!model.favorites.contains(where: { $0.id == beforeReplacement.last!.id }))
        precondition(Array(model.favorites.dropFirst()) == Array(beforeReplacement.dropLast()))
        precondition((try! FavoriteStore(url: url).load()) == model.favorites)
        model.latitude = "21"
        model.longitude = "31"
        model.returnToSelection()
        precondition(model.point?.latitude == 21 && model.point?.longitude == 31)
        precondition(backend.commands.isEmpty) // Saving, selecting, and deleting never write to the phone.

        let legacyURL = directory.appendingPathComponent("legacy.json")
        try! JSONEncoder().encode(Array(original.reversed())).write(to: legacyURL)
        let migrated = try! FavoriteStore(url: legacyURL).load()
        precondition(migrated == original)
        try! FavoriteStore(url: legacyURL).save(migrated)
        precondition((try! FavoriteStore(url: legacyURL).load()) == original) // Migration doesn't reverse on every launch.

        let blocked = directory.appendingPathComponent("blocked")
        try! Data().write(to: blocked)
        let failed = AppModel(preview: true, backend: TestDeviceBackend(), favoritesURL: blocked.appendingPathComponent("favorites.json"))
        failed.select(.init(latitude: 1, longitude: 2), name: "Test")
        precondition(!failed.addFavorite(name: "Test") && failed.favorites.isEmpty && failed.favoritesError != nil)
        let corrupted = directory.appendingPathComponent("corrupted.json")
        try! Data("invalid json".utf8).write(to: corrupted)
        let invalid = AppModel(preview: true, backend: TestDeviceBackend(), favoritesURL: corrupted)
        precondition(invalid.favorites.isEmpty && invalid.favoritesError != nil)
        print("Favorites checks passed: newest first, persistence, limit, confirmed replacement, cancellation, legacy migration, duplicates, removal, coordinate recentering, no device writes, storage failures")
    }

    @MainActor static func automaticConnectionChecks() async {
        let backend = TestDeviceBackend()
        let model = AppModel(preview: true, backend: backend)
        await model.checkForDevice()
        precondition(!model.connected && !model.busy)
        precondition(backend.commands == ["discover"])

        backend.deviceIDs = ["phone-b", "phone-a"]
        await model.checkForDevice()
        precondition(model.connected && model.state == "ready" && !model.busy)
        precondition(backend.preparedDevices == ["phone-a"])
        let commandCount = backend.commands.count
        await model.checkForDevice()
        precondition(backend.commands.count == commandCount) // Reuse a live session.

        model.select(.init(latitude: -33.8568, longitude: 151.2153), name: "Test target")
        model.receive(["event": "connectionLost"])
        backend.deviceIDs = []
        await model.checkForDevice()
        precondition(!model.connected && !model.canApply && model.state == "recovery_required")
        precondition(model.statusIsError)
        backend.deviceIDs = ["phone-a"]
        await model.checkForDevice()
        precondition(model.connected && model.canApply)
        precondition(!model.statusIsError && model.statusText == "手机已连接")
        precondition(!backend.commands.contains("setLocation")) // Replug never reapplies the target.
        await model.quit()
        let commandsAtQuit = backend.commands.count
        await model.checkForDevice()
        precondition(backend.commands.count == commandsAtQuit)

        let delayed = TestDeviceBackend()
        delayed.deviceIDs = ["phone-a"]
        delayed.holdPreparation = true
        let cancelledModel = AppModel(preview: true, backend: delayed)
        let attempt = Task { await cancelledModel.checkForDevice() }
        while delayed.preparation == nil { await Task.yield() }
        cancelledModel.cancel()
        await attempt.value
        while cancelledModel.busy { await Task.yield() }
        let commandsAtCancel = delayed.commands.count
        await cancelledModel.checkForDevice()
        precondition(!cancelledModel.connected && delayed.commands.count == commandsAtCancel + 1)
        precondition(delayed.commands.last == "discover") // Cancel stays cancelled until a replug.
        delayed.holdPreparation = false
        delayed.deviceIDs = []
        await cancelledModel.checkForDevice()
        delayed.deviceIDs = ["phone-a"]
        await cancelledModel.checkForDevice()
        precondition(cancelledModel.connected)
        await cancelledModel.quit()
        print("Automatic connection checks passed: absent, attach, multiple devices, session reuse, detach/replug, no automatic location write, quit, cancellation")
    }
}

@MainActor
private final class TestDeviceBackend: DeviceBackend {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var deviceIDs: [String] = []
    var commands: [String] = []
    var preparedDevices: [String] = []
    var locations: [TargetCoordinate] = []
    var failSetLocation = false
    var holdPreparation = false
    var preparation: CheckedContinuation<[String: Any], Error>?

    func start(preview: Bool, allowSigning: Bool) throws {}
    func send(_ command: String, values: [String: Any]) async throws -> [String: Any] {
        commands.append(command)
        switch command {
        case "setLocation":
            if failSetLocation { throw BackendFailure(message: "Test request failed") }
            locations.append(TargetCoordinate(.init(latitude: values["latitude"] as! Double, longitude: values["longitude"] as! Double)))
            return [:]
        case "discover": return ["devices": deviceIDs.map { ["id": $0] }]
        case "prepare":
            preparedDevices.append(values["deviceId"] as! String)
            if holdPreparation {
                return try await withCheckedThrowingContinuation { preparation = $0 }
            }
            return ["sessionId": UUID().uuidString]
        case "cancel", "disconnect":
            preparation?.resume(throwing: BackendFailure(message: "Cancelled"))
            preparation = nil
            return [:]
        default: preconditionFailure("Unexpected command: \(command)")
        }
    }
    func shutdown() {}
    func waitForExit() async {}
}

private struct SeededRandom: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
}

@MainActor
private final class FixedMapCoordinates: MapCoordinateResolving {
    let value: CoordinateSystem
    var fail = false
    init(_ value: CoordinateSystem) { self.value = value }
    func system(for coordinate: CLLocationCoordinate2D, countryCode: String?) async throws -> CoordinateSystem {
        if fail { throw MapCoordinates.Failure.unconfirmed }
        return value
    }
}
