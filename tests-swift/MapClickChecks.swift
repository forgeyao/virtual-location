import AppKit
import MapKit
import SwiftUI

// Exercise the actual ContentView gesture using native window events. The
// independent oracle is MKMapView's conversion of that same native event.
@main
struct MapClickChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("Map click check failed: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = NoDeviceBackend()
        let preferences = AppPreferences(url: nil)
        if ProcessInfo.processInfo.arguments.contains("--english") { preferences.language = .english }
        NSApp.appearance = NSAppearance(named: ProcessInfo.processInfo.arguments.contains("--dark") ? .darkAqua : .aqua)
        let model = AppModel(preview: true, backend: backend, favoritesURL: directory.appendingPathComponent("favorites.json"),
                             preferences: preferences, mapCoordinates: UnchangedMapCoordinates())
        let window = ClickWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 780),
                                 styleMask: AppWindowStyle.main, backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        let host = NSHostingView(rootView: ContentView(model: model))
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }

        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap { findMap($0) }.first
        }
        let center = CLLocationCoordinate2D(latitude: 23.003558, longitude: 113.3485861)
        var rows: [[String: Any]] = []
        for (width, span, heading, pitch) in [(1100.0, 0.02, 0.0, 0.0), (980.0, 0.002, 0.0, 0.0),
                                             (1100.0, 0.0, 137.0, 55.0)] {
            window.setContentSize(.init(width: width, height: 780))
            model.position = span > 0
                ? .region(.init(center: center, span: .init(latitudeDelta: span, longitudeDelta: span)))
                : .camera(MapCamera(centerCoordinate: center, distance: 1500, heading: heading, pitch: pitch))
            try await Task.sleep(for: .seconds(1))
            guard let map = findMap(host) else { throw Failure("Native map not found") }
            window.map = map
            for (dx, dy) in [(0.0, 0.0), (100.0, 80.0)] {
                let point = NSPoint(x: map.bounds.midX + dx, y: map.bounds.midY + dy)
                let requested = map.convert(point, toCoordinateFrom: map)
                let before = map.camera.copy() as! MKMapCamera
                let previous = model.point
                window.lastClick = nil
                let location = map.convert(point, to: nil)
                // Enqueue the complete click before yielding: a native map may
                // enter a tracking loop on mouseDown and wait for mouseUp.
                for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: rows.count + 1, clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0) else { throw Failure("Event creation failed") }
                    NSApp.postEvent(event, atStart: false)
                }
                for _ in 0..<40 {
                    if window.lastClick != nil,
                       model.point?.latitude != previous?.latitude || model.point?.longitude != previous?.longitude { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let actual = model.point, let native = window.lastClick else { throw Failure("Click was not delivered") }
                let locationError = distance(actual, native)
                guard distance(requested, native) < 0.01 else { throw Failure("Injected event did not hit the requested pixel") }
                guard locationError < 0.05 else { throw Failure("Gesture disagrees with native click by \(locationError) m") }
                var annotationView: MKAnnotationView?
                for _ in 0..<20 {
                    if let annotation = map.annotations.first(where: { distance($0.coordinate, actual) < 0.01 }),
                       let view = map.view(for: annotation), view.bounds.height > 0 {
                        annotationView = view; break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let annotationView else { throw Failure("Selected pin was not rendered") }
                let pinBounds = map.convert(annotationView.bounds, from: annotationView)
                let projected = map.convert(actual, toPointTo: map)
                let anchorError = hypot(pinBounds.midX - projected.x, pinBounds.maxY - projected.y)
                guard anchorError < 1 else { throw Failure("Pin tip is offset from selected coordinate by \(anchorError) pixels") }
                guard abs((Double(model.latitude) ?? .infinity) - native.latitude) < 1e-7,
                      abs((Double(model.longitude) ?? .infinity) - native.longitude) < 1e-7 else { throw Failure("Field coordinate differs") }
                guard distance(map.camera.centerCoordinate, before.centerCoordinate) < 0.01,
                      abs(map.camera.altitude - before.altitude) < 0.01,
                      abs(map.camera.heading - before.heading) < 0.01,
                      abs(map.camera.pitch - before.pitch) < 0.01 else { throw Failure("Click changed the camera") }
                rows.append(["width": width, "latitudeSpan": span, "heading": heading, "pitch": pitch,
                             "pixelX": point.x, "pixelY": point.y, "errorMeters": locationError, "pinAnchorErrorPixels": anchorError])
                if rows.count == 2, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = preferences.language == .english ? "en" : "zh"
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: ".build/map-click-layout-\(name).png"))
                }
            }
        }
        let result = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let output = URL(fileURLWithPath: ".build/map-click-checks.json")
        try result.write(to: output)
        await model.quit()
        print("\(rows.count) real ContentView map click checks passed: native event agreement, fields, resized window, zoom, heading, pitch and unchanged camera; no device access")
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

@MainActor
private final class ClickWindow: NSWindow {
    var map: MKMapView?
    var lastClick: CLLocationCoordinate2D?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp, let map {
            lastClick = map.convert(map.convert(event.locationInWindow, from: nil), toCoordinateFrom: map)
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class UnchangedMapCoordinates: MapCoordinateResolving {
    func system(for coordinate: CLLocationCoordinate2D, countryCode: String?) async throws -> CoordinateSystem { .wgs84 }
}

@MainActor
private final class NoDeviceBackend: DeviceBackend {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func start(preview: Bool, allowSigning: Bool) throws { preconditionFailure("Device access forbidden in map UI test") }
    func send(_ command: String, values: [String: Any]) async throws -> [String: Any] { preconditionFailure("Device access forbidden") }
    func shutdown() {}
    func waitForExit() async {}
}
