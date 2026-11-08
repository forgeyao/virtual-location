import Combine
import MapKit

@MainActor
final class PlaceSuggestions: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private var completer: MKLocalSearchCompleter?
    private var pending: Task<Void, Never>?

    func update(_ query: String, region: MKCoordinateRegion?) {
        clear()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            let source = MKLocalSearchCompleter()
            source.resultTypes = [.address, .pointOfInterest]
            if let region { source.region = region }
            source.delegate = self
            self.completer = source
            source.queryFragment = text
        }
    }

    func clear() {
        pending?.cancel()
        pending = nil
        completer?.delegate = nil
        completer?.cancel()
        completer = nil
        results = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor [weak self] in
            guard let self, completer === self.completer else { return }
            results = Array(completer.results.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, completer === self.completer else { return }
            results = [] // Explicit search and coordinate entry remain available.
        }
    }
}
