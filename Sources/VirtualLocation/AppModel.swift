import AppKit
import Combine
import MapKit
import SwiftUI

struct USBDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [USBDevice] = []
    @Published var latitude = "" { didSet { coordinateTextChanged() } }
    @Published var longitude = "" { didSet { coordinateTextChanged() } }
    @Published private(set) var coordinateSystem: CoordinateSystem = .gcj02
    @Published private(set) var coordinateMessage = ""
    @Published private(set) var lastRandomizedCoordinate: TargetCoordinate?
    @Published var point: CLLocationCoordinate2D?
    @Published var placeName = "尚未选择位置"
    private var generatedPlaceName = true
    @Published var query = "" { didSet { if !suppressSuggestions { queryChanged() } } }
    @Published var results: [MKMapItem] = []
    @Published var searching = false
    @Published var searchMessage = ""
    @Published var state = "disconnected"
    @Published var busy = false
    @Published var message = "连接 iPhone 后会自动准备，请保持手机解锁。"
    @Published var error: String?
    @Published var log: [String] = []
    @Published var elapsed: TimeInterval = 0
    @Published private(set) var favorites: [FavoriteLocation] = []
    @Published var favoritesError: String?
    @Published var position: MapCameraPosition = .region(.init(
        center: .init(latitude: 31.2304, longitude: 121.4737),
        span: .init(latitudeDelta: 0.08, longitudeDelta: 0.08)))
    let preview: Bool
    let backend: any DeviceBackend
    let preferences: AppPreferences
    let suggestions = PlaceSuggestions()
    private var suppressSuggestions = false
    private var sessionID: String?
    private var search: MKLocalSearch?
    private var searchGeneration = UUID()
    private var started: Date?
    private var timer: Timer?
    private var quitting = false
    private var automaticConnectionTask: Task<Void, Never>?
    private var discovering = false
    private var activeDeviceID = ""
    private var suppressedDeviceID = ""
    private var nextConnectionAttempt = Date.distantPast
    private var preparationStage = ""
    private var operationGeneration = UUID()
    private let favoriteStore: FavoriteStore
    private let mapCoordinates: any MapCoordinateResolving
    private var coordinateRevision = UUID()
    private var selectedInput: TargetCoordinate?
    private var selectedLegacyFavoriteID: UUID?
    private var selectionTask: Task<Void, Never>?
    private var assigningSelection = false
    private var coordinatesAreUserInput = true
    private var coordinatePreferenceObservation: AnyCancellable?

    init(preview: Bool, backend: (any DeviceBackend)? = nil, favoritesURL: URL? = nil, preferences: AppPreferences? = nil,
         mapCoordinates: (any MapCoordinateResolving)? = nil) {
        self.preview = preview
        self.backend = backend ?? Backend()
        self.preferences = preferences ?? AppPreferences()
        self.coordinateSystem = self.preferences.coordinateSystem
        self.mapCoordinates = mapCoordinates ?? MapCoordinates()
        let root = Backend.projectRoot() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        favoriteStore = FavoriteStore(url: favoritesURL ?? root.appendingPathComponent(
            preview ? ".state/preview/favorites.json" : ".state/favorites.json"))
        do { favorites = try favoriteStore.load() }
        catch { favoritesError = "无法读取收藏，请检查本地收藏文件。" }
        if preview { message = "界面预览使用模拟设备，不会连接或修改 iPhone。" }
        self.backend.onEvent = { [weak self] event in self?.receive(event) }
        self.backend.onExit = { [weak self] in
            guard let self else { return }
            if self.quitting { return }
            self.busy = false
            self.sessionID = nil
            if !self.quitting {
                self.state = "recovery_required"
                self.error = "后台已退出。若此前正在模拟，请在手机确认位置状态。"
                self.nextConnectionAttempt = Date().addingTimeInterval(10)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let self, self.busy, let started = self.started { self.elapsed = Date().timeIntervalSince(started) }
            }
        }
        coordinatePreferenceObservation = self.preferences.$coordinateSystem.dropFirst().removeDuplicates().sink { [weak self] system in
            guard let self, self.coordinatesAreUserInput else { return }
            self.setInputCoordinateSystem(system)
        }
        if let saved = self.preferences.lastSelection { restoreSelection(saved) }
    }

    private func restoreSelection(_ saved: SavedLocation) {
        assigningSelection = true
        latitude = saved.isUserInput ? String(saved.coordinate.latitude)
            : String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), saved.coordinate.latitude)
        longitude = saved.isUserInput ? String(saved.coordinate.longitude)
            : String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), saved.coordinate.longitude)
        assigningSelection = false
        coordinateSystem = saved.coordinateSystem
        selectedInput = coordinate
        placeName = saved.name
        generatedPlaceName = saved.generatedName
        coordinatesAreUserInput = saved.isUserInput
        selectedLegacyFavoriteID = saved.legacyFavoriteID
        if let point = saved.mapCoordinate {
            showMapPoint(point.location, recenter: true)
        } else {
            showInputOnMap(recenter: true)
        }
        if coordinateSystem == .unresolved { coordinateMessage = "请先确认坐标系。" }
    }

    private func saveSelection() {
        guard let coordinate else { return }
        let matchesSelection = selectedInput == coordinate
        preferences.lastSelection = SavedLocation(
            coordinate: coordinate, coordinateSystem: coordinateSystem,
            name: matchesSelection ? placeName : "经纬度选点",
            generatedName: matchesSelection ? generatedPlaceName : true,
            isUserInput: coordinatesAreUserInput,
            mapCoordinate: matchesSelection ? point.map(TargetCoordinate.init) : nil,
            legacyFavoriteID: selectedLegacyFavoriteID)
    }

    private func coordinateTextChanged() {
        coordinateRevision = UUID()
        guard !assigningSelection else { return }
        selectionTask?.cancel()
        coordinatesAreUserInput = true
        selectedLegacyFavoriteID = nil
        coordinateSystem = preferences.coordinateSystem
        coordinateMessage = ""
        saveSelection()
    }

    var connected: Bool { sessionID != nil }
    var canApply: Bool { connected && !busy && ["ready", "simulating"].contains(state) && deviceCoordinate != nil }
    var coordinate: TargetCoordinate? { TargetCoordinate(latitude: latitude, longitude: longitude) }
    // This is the only coordinate consumed by the device boundary. Displayed
    // map/input values and favourites retain their explicitly tagged datum.
    var deviceCoordinate: TargetCoordinate? { coordinate.flatMap { coordinateSystem.toWGS84($0) } }
    var currentFavorite: FavoriteLocation? {
        guard let coordinate else { return nil }
        return favorites.first { $0.matches(coordinate, system: coordinateSystem) }
    }
    var statusTitle: String { preferences.text(Self.stageNames[state] ?? "正在处理") }
    var statusIsError: Bool { error != nil || state == "recovery_required" }
    var statusText: String {
        if let error { return preferences.text(error) }
        if state == "recovery_required" { return preferences.text("定位状态待确认，请在手机地图核对位置。") }
        return statusTitle
    }
    var displayPlaceName: String { generatedPlaceName ? preferences.text(placeName) : placeName }
    var localizedLog: [String] {
        log.map { line in
            guard let separator = line.range(of: "  ") else { return preferences.text(line) }
            return String(line[..<separator.upperBound]) + preferences.text(String(line[separator.upperBound...]))
        }
    }
    static let stageNames = [
        "disconnected": "等待 iPhone", "discovering": "发现设备", "trust_and_developer_mode": "检查信任与开发者模式",
        "checking_image": "检查开发组件", "preparing_image": "准备开发组件", "mounting_image": "加载开发组件",
        "opening_tunnel": "建立连接", "opening_location_service": "连接定位服务", "recovering": "清理上次会话",
        "ready": "手机已连接", "simulating": "定位修改已发送", "stopping": "正在停止", "retrying": "连接暂不可用，正在重试",
        "recovery_required": "定位状态待确认"
    ]

    func receive(_ event: [String: Any]) {
        if let stage = event["stage"] as? String {
            if busy && !["disconnected", "recovery_required"].contains(stage) { preparationStage = stage }
            state = stage
            appendLog(Self.stageNames[stage] ?? stage)
            if stage == "disconnected" { sessionID = nil }
            if stage == "recovery_required" { sessionID = event["sessionId"] as? String }
        }
        if event["event"] as? String == "connectionLost" {
            sessionID = nil
            state = "recovery_required"
            error = event["message"] as? String ?? "连接已断开，请在手机确认位置状态。"
            message = "等待 iPhone 重新接入，连接后会先清理上次会话。"
        }
    }

    func appendLog(_ text: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    func perform(_ action: @escaping () async throws -> Void) {
        let token = UUID()
        operationGeneration = token
        busy = true; error = nil; elapsed = 0; started = Date()
        Task {
            do { try await action() }
            catch {
                if operationGeneration == token { self.error = error.localizedDescription; appendLog(error.localizedDescription) }
            }
            if operationGeneration == token { busy = false }
        }
    }

    func startAutomaticConnection() {
        guard automaticConnectionTask == nil, !quitting else { return }
        automaticConnectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.quitting else { return }
                await self.checkForDevice()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stopAutomaticConnection() {
        automaticConnectionTask?.cancel()
        automaticConnectionTask = nil
    }

    func checkForDevice() async {
        guard !quitting, !Task.isCancelled, !connected, !busy, !discovering,
              Date() >= nextConnectionAttempt else { return }
        discovering = true
        defer { discovering = false }
        var preparationToken: UUID?
        defer {
            if let token = preparationToken, operationGeneration == token { busy = false }
        }
        do {
            // Desktop mode enables signing during automatic preparation; see
            // the README data-transfer disclosure. Mounted images skip signing.
            try backend.start(preview: preview, allowSigning: true)
            let data = try await backend.send("discover")
            guard !quitting, !Task.isCancelled, !busy, !connected else { return }
            devices = (data["devices"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return USBDevice(id: id, name: item["name"] as? String ?? "USB iPhone · \(id.suffix(4))")
            }.sorted { $0.id < $1.id }
            if !devices.contains(where: { $0.id == suppressedDeviceID }) { suppressedDeviceID = "" }
            guard let device = devices.first else {
                activeDeviceID = ""
                if state != "recovery_required" {
                    state = "disconnected"
                    message = "等待 iPhone 接入，请解锁手机并确认信任此电脑。"
                    error = nil
                }
                return
            }
            guard device.id != suppressedDeviceID else { return }
            activeDeviceID = device.id
            let token = UUID()
            preparationToken = token
            operationGeneration = token
            busy = true; error = nil; elapsed = 0; started = Date()
            preparationStage = "discovering"
            message = "正在自动连接 iPhone，请保持手机解锁。"
            let prepared = try await backend.send("prepare", values: ["deviceId": device.id])
            guard !quitting, !Task.isCancelled, operationGeneration == token else { return }
            sessionID = prepared["sessionId"] as? String
            state = "ready"
            message = "设备已就绪。选择目标位置后，点击修改定位。"
        } catch {
            guard !quitting, !Task.isCancelled else { return }
            if let token = preparationToken, operationGeneration != token { return }
            self.error = error.localizedDescription
            appendLog(error.localizedDescription)
            nextConnectionAttempt = Date().addingTimeInterval(10)
            // Do not repeat signing, mounting, or uncertain recovery on a timer.
            if preparationToken != nil && ["preparing_image", "mounting_image", "recovering"].contains(preparationStage) {
                suppressedDeviceID = activeDeviceID
                message = "请检查手机状态，重新插入 iPhone 后自动重试。"
            } else {
                message = "请解锁 iPhone 并确认信任，稍后将自动重试。"
            }
        }
    }

    func apply() {
        guard let center = deviceCoordinate, let sessionID, canApply else { return }
        saveSelection()
        let randomized = preferences.randomLocationEnabled
        var generator = SystemRandomNumberGenerator()
        let coordinate = randomized ? preferences.randomLocationRange.offset(from: center, using: &generator) : center
        perform { [self] in
            let data = try await backend.send("setLocation", values: ["sessionId": sessionID,
                "latitude": coordinate.latitude, "longitude": coordinate.longitude])
            state = "simulating"
            lastRandomizedCoordinate = randomized ? coordinate : nil
            message = preview ? "预览：模拟指令已发送，未操作真实设备。" : (data["verification"] as? String ?? "请在手机地图核对实际位置。")
            appendLog("已发送设置请求")
        }
    }

    func stop() {
        perform { [self] in
            let data = try await backend.send("clear")
            message = preview ? "预览：模拟停止请求完成。" : (data["verification"] as? String ?? "请在手机确认恢复。")
            appendLog("清除请求已发送，恢复结果待手机确认")
        }
    }

    func disconnect() {
        suppressedDeviceID = activeDeviceID
        perform { [self] in
            _ = try await backend.send("disconnect")
            sessionID = nil
            message = state == "recovery_required" ? "请重连后清理，并在手机确认位置。" : "设备会话已断开。"
        }
    }

    func cancel() {
        suppressedDeviceID = activeDeviceID
        perform { [self] in
            _ = try await backend.send("cancel")
            sessionID = nil
            message = "操作已取消。重新插入 iPhone 后会自动连接。"
        }
    }

    func select(_ coordinate: CLLocationCoordinate2D, name: String, generatedName: Bool = false, recenter: Bool = true,
                system: CoordinateSystem = .wgs84) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        selectionTask?.cancel()
        selectedLegacyFavoriteID = nil
        assigningSelection = true
        latitude = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude)
        longitude = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude)
        assigningSelection = false
        coordinatesAreUserInput = false
        selectedInput = self.coordinate
        coordinateSystem = system
        coordinateMessage = ""
        placeName = name
        generatedPlaceName = generatedName
        showInputOnMap(recenter: recenter)
        saveSelection()
    }

    func selectMapPoint(_ coordinate: CLLocationCoordinate2D) {
        selectMapCoordinate(coordinate, name: "地图选点", generatedName: true, recenter: false)
    }

    func selectMapCoordinate(_ coordinate: CLLocationCoordinate2D, name: String, generatedName: Bool = false,
                             recenter: Bool = true, countryCode: String? = nil) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        selectionTask?.cancel()
        selectedLegacyFavoriteID = nil
        assigningSelection = true
        latitude = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude)
        longitude = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude)
        assigningSelection = false
        coordinatesAreUserInput = false
        selectedInput = self.coordinate
        placeName = name; generatedPlaceName = generatedName
        showMapPoint(coordinate, recenter: recenter)
        guard ChinaCoordinates.mayNeedConversion(coordinate) else {
            coordinateSystem = .wgs84
            coordinateMessage = ""
            saveSelection()
            return
        }
        coordinateSystem = .unresolved
        coordinateMessage = "正在确认地图坐标系…"
        saveSelection()
        let revision = coordinateRevision
        selectionTask = Task {
            do {
                let system = try await mapCoordinates.system(for: coordinate, countryCode: countryCode)
                guard !Task.isCancelled, revision == coordinateRevision, coordinateSystem == .unresolved else { return }
                coordinateSystem = system
                coordinateMessage = ""
                saveSelection()
            } catch {
                guard !Task.isCancelled, revision == coordinateRevision else { return }
                coordinateMessage = "无法确认地图坐标系，请重试选点或在设置中确认。"
            }
        }
    }

    func setInputCoordinateSystem(_ system: CoordinateSystem) {
        selectionTask?.cancel()
        coordinateRevision = UUID()
        coordinateSystem = system
        coordinateMessage = ""
        if system != .unresolved, let id = selectedLegacyFavoriteID, let coordinate,
           let index = favorites.firstIndex(where: { $0.id == id && $0.coordinateSystem == nil }),
           abs(favorites[index].latitude - coordinate.latitude) < 1e-7,
           abs(favorites[index].longitude - coordinate.longitude) < 1e-7 {
            var updated = favorites
            updated[index].coordinateSystem = system
            if saveFavorites(updated) { selectedLegacyFavoriteID = nil }
        }
        showInputOnMap(recenter: false)
        saveSelection()
    }

    private func showMapPoint(_ coordinate: CLLocationCoordinate2D, recenter: Bool) {
        point = coordinate
        if recenter { position = .region(.init(center: coordinate, span: .init(latitudeDelta: 0.018, longitudeDelta: 0.018))) }
    }

    private func showInputOnMap(recenter: Bool) {
        guard let input = coordinate, let wgs = deviceCoordinate else { point = nil; return }
        let revision = coordinateRevision
        selectedInput = input
        guard ChinaCoordinates.mayNeedConversion(wgs.location) else {
            showMapPoint(wgs.location, recenter: recenter); return
        }
        point = nil
        selectionTask = Task {
            do {
                let mapSystem = try await mapCoordinates.system(for: wgs.location, countryCode: nil)
                guard !Task.isCancelled, revision == coordinateRevision else { return }
                let display = mapSystem == .gcj02 ? ChinaCoordinates.toGCJ02(wgs.location) : wgs.location
                showMapPoint(display, recenter: recenter)
                saveSelection()
            } catch {
                guard !Task.isCancelled, revision == coordinateRevision else { return }
                coordinateMessage = "地图暂不可用，仍可使用已知坐标修改定位。"
            }
        }
    }

    func locateInput() {
        guard let coordinate else { error = "请输入有效经纬度：纬度 −90 至 90，经度 −180 至 180。"; return }
        select(coordinate.location, name: "经纬度选点", generatedName: true, system: coordinateSystem)
        coordinatesAreUserInput = true
        saveSelection()
        error = nil
    }

    func returnToSelection() {
        // Do not cancel a pending map detection or lose an old favourite's
        // confirmation context while its input datum is still unknown.
        guard let coordinate, coordinateSystem != .unresolved else { return }
        if selectedInput != coordinate || point == nil {
            let userInput = coordinatesAreUserInput
            select(coordinate.location, name: "经纬度选点", generatedName: true, system: coordinateSystem)
            coordinatesAreUserInput = userInput
            saveSelection()
            return
        }
        guard let point else { return }
        position = .region(.init(center: point, span: .init(latitudeDelta: 0.018, longitudeDelta: 0.018)))
    }

    @discardableResult
    func addFavorite(name: String, replacingOldest: Bool = false) -> Bool {
        guard let coordinate else { favoritesError = "请先选择位置或输入有效经纬度。"; return false }
        guard coordinateSystem != .unresolved else { favoritesError = "请先确认坐标系。"; return false }
        if currentFavorite != nil { favoritesError = nil; return true }
        guard favorites.count < FavoriteStore.limit || replacingOldest else { favoritesError = "最多收藏 5 个位置。"; return false }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { favoritesError = "请填写收藏名称。"; return false }
        let favorite = FavoriteLocation(id: UUID(), name: String(title.prefix(60)),
                                        latitude: coordinate.latitude, longitude: coordinate.longitude, coordinateSystem: coordinateSystem)
        return saveFavorites([favorite] + favorites.prefix(FavoriteStore.limit - 1))
    }

    func removeFavorite(_ favorite: FavoriteLocation) {
        _ = saveFavorites(favorites.filter { $0.id != favorite.id })
    }

    @discardableResult
    func renameFavorite(_ favorite: FavoriteLocation, name: String) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { favoritesError = "请填写收藏名称。"; return false }
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else {
            favoritesError = "收藏已不存在。"; return false
        }
        var updated = favorites
        let existing = updated[index]
        let renamed = FavoriteLocation(id: existing.id, name: String(title.prefix(60)),
                                       latitude: existing.latitude, longitude: existing.longitude, coordinateSystem: existing.coordinateSystem)
        updated[index] = renamed
        guard saveFavorites(updated) else { return false }
        if let coordinate, existing.matches(coordinate, system: coordinateSystem) {
            placeName = renamed.name
            generatedPlaceName = false
            saveSelection()
        }
        return true
    }

    func selectFavorite(_ favorite: FavoriteLocation) {
        let location = CLLocationCoordinate2D(latitude: favorite.latitude, longitude: favorite.longitude)
        let system = favorite.coordinateSystem ?? (ChinaCoordinates.mayNeedConversion(location) ? .unresolved : .wgs84)
        select(location, name: favorite.name, system: system)
        selectedLegacyFavoriteID = favorite.coordinateSystem == nil ? favorite.id : nil
        saveSelection()
        if system == .unresolved { coordinateMessage = "旧收藏未记录坐标系，请在设置中确认或重新从地图选点。" }
    }

    private func saveFavorites(_ updated: [FavoriteLocation]) -> Bool {
        do {
            try favoriteStore.save(updated)
            favorites = updated
            favoritesError = nil
            return true
        } catch {
            favoritesError = "无法保存收藏，请检查本地存储权限。"
            return false
        }
    }

    private func resetSearch() {
        search?.cancel()
        search = nil
        searchGeneration = UUID()
        results = []; searching = false; searchMessage = ""
    }

    private func queryChanged() {
        resetSearch()
        let region = point.map { MKCoordinateRegion(center: $0, span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5)) }
        suggestions.update(query, region: region)
    }

    func clearSearch() {
        suppressSuggestions = true
        query = ""
        suppressSuggestions = false
        resetSearch()
        suggestions.clear()
    }

    func dismissSearchResults() {
        resetSearch()
        suggestions.clear()
    }

    func selectSearchResult(_ item: MKMapItem) {
        suppressSuggestions = true
        query = item.name ?? query
        suppressSuggestions = false
        dismissSearchResults()
        selectMapCoordinate(item.placemark.coordinate, name: item.name ?? "搜索结果", countryCode: item.placemark.isoCountryCode)
    }

    func selectSuggestion(_ completion: MKLocalSearchCompletion) {
        suppressSuggestions = true
        query = completion.title
        suppressSuggestions = false
        searchPlaces(completion: completion)
    }

    func searchPlaces(completion: MKLocalSearchCompletion? = nil) {
        resetSearch()
        suggestions.clear()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; searching = false; searchGeneration = UUID(); return }
        let token = UUID(); searchGeneration = token
        searching = true; searchMessage = ""
        let request = completion.map { MKLocalSearch.Request(completion: $0) } ?? MKLocalSearch.Request()
        if completion == nil { request.naturalLanguageQuery = text }
        let active = MKLocalSearch(request: request); search = active
        Task {
            do {
                let response = try await active.start()
                guard searchGeneration == token else { return }
                results = Array(response.mapItems.prefix(8))
                searchMessage = results.isEmpty ? "没有找到地点，可以直接输入经纬度。" : ""
                if completion != nil, let item = response.mapItems.first { selectSearchResult(item) }
            } catch {
                guard searchGeneration == token else { return }
                results = []; searchMessage = "搜索暂不可用，仍可输入经纬度选点。"
            }
            if searchGeneration == token { searching = false }
        }
    }

    func quit() async {
        quitting = true
        stopAutomaticConnection()
        search?.cancel()
        selectionTask?.cancel()
        suggestions.clear()
        backend.shutdown()
        await backend.waitForExit()
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = preferences.text("虚拟定位诊断.txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.3"
        let header = "Virtual Location \(version)\n\(preferences.text("模式")): \(preferences.text(preview ? "界面预览" : "真实设备"))\n\(preferences.text("状态")): \(statusText)\n"
        do { try (header + localizedLog.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "无法保存诊断文件。" }
    }
}
