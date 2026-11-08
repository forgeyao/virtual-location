import AppKit
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var terminating = false
    private var cleanupStarted = false
    private var model: AppModel!
    private var smokeFavoritesURL: URL?
    private var preferences: AppPreferences!
    private var settingsWindow: NSWindow?
    private let launchLanguage: AppLanguage

    init(launchLanguage: AppLanguage) {
        self.launchLanguage = launchLanguage
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let smokeFavorites = args.contains("--ui-smoke") && args.contains("--preview")
            ? FileManager.default.temporaryDirectory.appendingPathComponent("virtual-location-smoke-\(UUID()).json") : nil
        let root = Backend.projectRoot() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        preferences = AppPreferences(url: smokeFavorites != nil ? nil : root.appendingPathComponent(
            args.contains("--preview") ? ".state/preview/preferences.json" : ".state/preferences.json"), launchLanguage: launchLanguage)
        if args.contains("--preview") {
            if let i = args.firstIndex(of: "--appearance"), args.count > i + 1,
               let value = AppAppearance(rawValue: args[i + 1]) { preferences.appearance = value }
            if let i = args.firstIndex(of: "--language"), args.count > i + 1,
               let value = AppLanguage(rawValue: args[i + 1]) { preferences.language = value }
        }
        model = AppModel(preview: args.contains("--preview"), favoritesURL: smokeFavorites, preferences: preferences)
        smokeFavoritesURL = smokeFavorites
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = BrandArtwork.image()
        applyAppearance()
        preferences.onChange = { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            self.settingsWindow?.title = self.tr("设置")
            self.buildMenu()
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                          styleMask: AppWindowStyle.main, backing: .buffered, defer: false)
        window.title = model.preview ? "虚拟定位 · 界面预览" : "虚拟定位"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 980, height: 720)
        window.contentView = NSHostingView(rootView: ContentView(model: model,
            onOpenSettings: { [weak self] in self?.showSettings() }))
        window.isReleasedWhenClosed = false
        window.center()
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.startAutomaticConnection()
        if args.contains("--ui-smoke"), model.preview {
            Task { await smoke(args) }
        }
    }

    private func buildMenu() {
        let main = NSMenu(), app = NSMenu(title: tr("虚拟定位")), item = NSMenuItem(title: tr("虚拟定位"), action: nil, keyEquivalent: "")
        app.addItem(withTitle: tr("关于虚拟定位"), action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(withTitle: tr("设置…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: tr("显示窗口"), action: #selector(showWindow), keyEquivalent: "0").target = self
        app.addItem(withTitle: tr("还原定位"), action: #selector(stop), keyEquivalent: ".").target = self
        app.addItem(.separator())
        app.addItem(withTitle: tr("退出虚拟定位"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; main.addItem(item)
        let edit = NSMenu(title: tr("编辑")), editItem = NSMenuItem(title: tr("编辑"), action: nil, keyEquivalent: "")
        edit.addItem(withTitle: tr("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        statusItem.button?.image = BrandArtwork.menuBarImage()
        let menu = NSMenu()
        menu.addItem(withTitle: tr("显示虚拟定位"), action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("还原定位"), action: #selector(stop), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("设置…"), action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    private func applyAppearance() {
        // One owner for native windows and SwiftUI. In particular, nil must
        // clear every explicit window appearance when following the system.
        NSApp.appearance = preferences.appearance.appearance
        for window in NSApp.windows {
            window.appearance = nil
            window.contentView?.needsDisplay = true
        }
    }

    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showAbout() {
        let artwork = BrandArtwork.image(size: 128)
        // Give the standard panel a concrete image representation instead of
        // relying on its cached/default bundle icon lookup.
        let icon = artwork.tiffRepresentation.flatMap { NSImage(data: $0) } ?? artwork
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: icon,
            .applicationName: tr("虚拟定位"),
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.3",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "5",
        ])
    }
    private func tr(_ key: String) -> String { preferences.text(key) }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 448, height: 270),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SettingsView(model: model,
                diagnosticsExpanded: model.preview && ProcessInfo.processInfo.arguments.contains("--show-diagnostics")))
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.title = tr("设置")
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func stop() { if model.connected { model.stop() }; showWindow() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        guard !cleanupStarted else { return .terminateCancel }
        cleanupStarted = true
        // Cancel this termination attempt, clean up on the normal run loop, then
        // initiate a fresh attempt. This avoids AppKit's nested termination loop.
        Task {
            await model.quit()
            terminating = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return .terminateCancel
    }

    private func settle() async {
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(100))
            if !model.busy { return }
        }
    }

    private func smoke(_ args: [String]) async {
        for _ in 0..<200 {
            if model.connected && !model.busy { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let automaticallyConnected = model.connected && model.state == "ready"
        if args.contains("--sample-favorites") {
            for (name, latitude, longitude) in [("悉尼歌剧院", -33.8568, 151.2153), ("上海外滩", 31.2400, 121.4900),
                                              ("北京天坛", 39.8822, 116.4066), ("杭州西湖", 30.2431, 120.1500),
                                              ("东京塔", 35.6586, 139.7454)] {
                let englishNames = ["悉尼歌剧院": "Sydney Opera House", "上海外滩": "The Bund", "北京天坛": "Temple of Heaven",
                                    "杭州西湖": "West Lake", "东京塔": "Tokyo Tower"]
                let title = preferences.language == .english ? englishNames[name] ?? name : name
                model.select(.init(latitude: latitude, longitude: longitude), name: title)
                model.addFavorite(name: title)
            }
        }
        model.select(.init(latitude: -33.8568, longitude: 151.2153),
                     name: preferences.language == .chinese ? "悉尼歌剧院 · 界面预览" : "Sydney Opera House · Preview")
        if let i = args.firstIndex(of: "--search-query"), args.count > i + 1 {
            model.query = args[i + 1]
            for _ in 0..<80 {
                if !model.suggestions.results.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        model.apply(); await settle()
        try? await Task.sleep(for: .seconds(2))
        let nativeMenuTitles = applicationMenuAccessibilityTitles()
        var snapshotSaved = false
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1,
           let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                do { try data.write(to: URL(fileURLWithPath: args[index + 1])); snapshotSaved = true }
                catch { }
            }
        }
        var aboutSnapshotSaved = false
        if let index = args.firstIndex(of: "--about-snapshot"), args.count > index + 1 {
            showAbout()
            try? await Task.sleep(for: .milliseconds(400))
            if let about = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.level == .normal }),
               let view = about.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    do { try data.write(to: URL(fileURLWithPath: args[index + 1])); aboutSnapshotSaved = true }
                    catch { }
                }
                about.close()
            }
        }
        var settingsSnapshotSaved = false
        if let i = args.firstIndex(of: "--settings-snapshot"), args.count > i + 1 {
            showSettings()
            try? await Task.sleep(for: .milliseconds(300))
            settingsSnapshotSaved = snapshot(settingsWindow?.contentView, path: args[i + 1])
            settingsWindow?.close()
        }
        var replacementSnapshotSaved = false
        var nativeButtonsVerified = false
        if let i = args.firstIndex(of: "--replacement-snapshot"), args.count > i + 1 {
            let alert = AppDialogs.replacementAlert(oldestName: model.favorites.last?.name ?? "Test", preferences: preferences)
            nativeButtonsVerified = alert.buttons[0].keyEquivalent == "\u{1b}"
                && alert.buttons[1].keyEquivalent == "\r" && !alert.buttons[1].hasDestructiveAction
                && alert.window.defaultButtonCell === (alert.buttons[1].cell as? NSButtonCell)
            alert.beginSheetModal(for: window) { _ in }
            try? await Task.sleep(for: .milliseconds(400))
            replacementSnapshotSaved = snapshot(window.attachedSheet?.contentView, path: args[i + 1])
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        }
        let suggestionCount = model.suggestions.results.count
        var suggestionResolved = false
        if args.contains("--resolve-suggestion"), let completion = model.suggestions.results.first {
            let previousName = model.placeName
            model.selectSuggestion(completion)
            for _ in 0..<100 {
                if !model.searching { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            suggestionResolved = !model.searching && model.searchMessage.isEmpty && model.placeName != previousName
        }
        model.clearSearch()
        try? await Task.sleep(for: .milliseconds(400))
        let searchCleared = model.query.isEmpty && model.suggestions.results.isEmpty && model.results.isEmpty && !model.searching
        let oldLanguage = preferences.language
        preferences.language = oldLanguage == .chinese ? .english : .chinese
        try? await Task.sleep(for: .milliseconds(250))
        let languageSwitched = NSApp.mainMenu?.items.first?.submenu?.items.first?.title == tr("关于虚拟定位")
        let menuRestartIndicated = preferences.requiresRelaunch
        preferences.language = oldLanguage
        let originalAppearance = preferences.appearance
        var appearanceCycleSaved = false
        if let i = args.firstIndex(of: "--appearance-cycle-dir"), args.count > i + 1 {
            let directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            showSettings()
            var saved = true
            for (index, choice) in [AppAppearance.light, .system, .light, .system, .dark, .system].enumerated() {
                preferences.appearance = choice
                try? await Task.sleep(for: .milliseconds(250))
                saved = snapshot(settingsWindow?.contentView,
                                 path: directory.appendingPathComponent("\(index)-\(choice.rawValue).png").path) && saved
            }
            appearanceCycleSaved = saved
            settingsWindow?.close()
        }
        preferences.appearance = .light
        try? await Task.sleep(for: .milliseconds(150))
        let lightApplied = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        preferences.appearance = .dark
        try? await Task.sleep(for: .milliseconds(150))
        let darkApplied = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        preferences.appearance = .system
        try? await Task.sleep(for: .milliseconds(150))
        let systemApplied = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        preferences.appearance = originalAppearance
        let simulated = model.state == "simulating"
        model.stop(); await settle()
        let cleared = model.state == "ready"
        model.stopAutomaticConnection()
        model.disconnect(); await settle()
        let result: [String: Any] = ["preview": true, "simulated": simulated,
            "automaticallyConnected": automaticallyConnected,
            "titleHidden": window.titleVisibility == .hidden, "aboutSnapshotSaved": aboutSnapshotSaved,
            "settingsSnapshotSaved": settingsSnapshotSaved, "replacementSnapshotSaved": replacementSnapshotSaved,
            "nativeButtonsVerified": nativeButtonsVerified, "suggestionCount": suggestionCount,
            "suggestionResolved": suggestionResolved, "appearanceSwitched": lightApplied && darkApplied && systemApplied,
            "searchCleared": searchCleared, "languageSwitched": languageSwitched,
            "nativeMenuTitles": nativeMenuTitles, "nativeMenuLocalizedOnLaunch": nativeMenuTitles.contains(tr("虚拟定位")),
            "menuRestartIndicated": menuRestartIndicated,
            "appearanceCycleSaved": appearanceCycleSaved,
            "cleared": cleared, "disconnected": model.state == "disconnected", "snapshotSaved": snapshotSaved]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        fflush(stdout)
        if let smokeFavoritesURL { try? FileManager.default.removeItem(at: smokeFavoritesURL) }
        // Termination enters AppKit's nested event loop. Leave the current actor task
        // before invoking it so the asynchronous cleanup task can run.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func applicationMenuAccessibilityTitles() -> [String] {
        guard let menuBar = NSApp.accessibilityMenuBar() as? NSAccessibilityProtocol,
              let children = menuBar.accessibilityChildren() else { return [] }
        return children.compactMap { item in
            guard let accessible = item as? NSAccessibilityProtocol else { return nil }
            return accessible.accessibilityTitle() ?? accessible.accessibilityLabel()
        }
    }

    private func snapshot(_ view: NSView?, path: String) -> Bool {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Window backgrounds aren't part of a content-view cache. Composite the
        // captured view over its actual appearance for a faithful opaque preview.
        guard let captured = rep.cgImage,
              let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: output)?.cgContext else { return false }
        let rect = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(rect)
        }
        context.draw(captured, in: rect)
        guard let data = output.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true }
        catch { return false }
    }
}

@main
struct VirtualLocationApplication {
    @MainActor static func main() {
        let language = AppPreferences.languageForLaunch(arguments: ProcessInfo.processInfo.arguments)
        AppPreferences.configureLaunchLanguage(language)
        let app = NSApplication.shared
        let delegate = ApplicationDelegate(launchLanguage: language)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) { }
    }
}
