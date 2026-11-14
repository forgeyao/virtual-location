import AppKit
import Combine

enum AppAppearance: String, Codable, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: "跟随系统"; case .light: "白色"; case .dark: "暗黑" } }
    var appearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}

enum AppLanguage: String, Codable, CaseIterable {
    case chinese = "zh-Hans", english = "en"
    var title: String { self == .chinese ? "中文" : "English" }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var appearance: AppAppearance = .system { didSet { save(); onChange?() } }
    @Published var language: AppLanguage = .chinese { didSet { save(); onChange?() } }
    @Published var coordinateSystem: CoordinateSystem = .gcj02 { didSet { save(); onChange?() } }
    @Published var randomLocationEnabled = false { didSet { save() } }
    @Published var randomLocationRange: RandomLocationRange = .fifty { didSet { save() } }
    @Published private(set) var error: String?
    var onChange: (() -> Void)?
    private let url: URL?
    private var launchLanguage: AppLanguage = .chinese
    var requiresRelaunch: Bool { language != launchLanguage }

    init(url: URL? = nil, launchLanguage: AppLanguage? = nil) {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do {
                let values = try JSONDecoder().decode(Values.self, from: Data(contentsOf: url))
                appearance = values.appearance
                language = values.language
                coordinateSystem = values.coordinateSystem.flatMap { $0 == .unresolved ? nil : $0 } ?? .gcj02
                randomLocationEnabled = values.randomLocationEnabled ?? false
                randomLocationRange = values.randomLocationRange.flatMap(RandomLocationRange.init(rawValue:)) ?? .fifty
            } catch { self.error = "无法读取设置，已使用默认设置。" }
        }
        self.launchLanguage = launchLanguage ?? language
    }

    static func languageForLaunch(arguments: [String]) -> AppLanguage {
        if arguments.contains("--preview"), let index = arguments.firstIndex(of: "--language"), arguments.count > index + 1,
           let choice = AppLanguage(rawValue: arguments[index + 1]) { return choice }
        if arguments.contains("--preview") && arguments.contains("--ui-smoke") { return .chinese }
        let root = Backend.projectRoot() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = root.appendingPathComponent(arguments.contains("--preview") ? ".state/preview/preferences.json" : ".state/preferences.json")
        guard let data = try? Data(contentsOf: path), let values = try? JSONDecoder().decode(Values.self, from: data) else { return .chinese }
        return values.language
    }

    static func configureLaunchLanguage(_ language: AppLanguage) {
        // Match Xcode's per-launch AppleLanguages override before AppKit/MapKit
        // cache main-bundle localizations. Do not change system preferences.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [language.rawValue]
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func text(_ key: String) -> String { language == .chinese ? key : Self.english[key] ?? key }
    func format(_ key: String, _ args: CVarArg...) -> String { String(format: text(key), arguments: args) }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let values = Values(appearance: appearance, language: language, coordinateSystem: coordinateSystem,
                                randomLocationEnabled: randomLocationEnabled, randomLocationRange: randomLocationRange.rawValue)
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil
        } catch { self.error = "无法保存设置，请检查本地存储权限。" }
    }

    private struct Values: Codable {
        let appearance: AppAppearance
        let language: AppLanguage
        let coordinateSystem: CoordinateSystem?
        let randomLocationEnabled: Bool?
        let randomLocationRange: Int?
    }

    static let english: [String: String] = [
        "虚拟定位": "Virtual Location", "设置": "Settings", "设置…": "Settings…",
        "关于虚拟定位": "About Virtual Location", "显示窗口": "Show Window", "退出虚拟定位": "Quit Virtual Location",
        "显示虚拟定位": "Show Virtual Location", "退出": "Quit", "编辑": "Edit", "剪切": "Cut", "复制": "Copy",
        "粘贴": "Paste", "全选": "Select All", "外观": "Appearance", "语言": "Language",
        "跟随系统": "Follow System", "白色": "Light", "暗黑": "Dark",
        "设置自动保存并立即生效。": "Changes are saved and applied immediately.",
        "菜单栏应用名将在重新打开应用后更新。": "The menu bar app name updates when you reopen the app.",
        "无法读取设置，已使用默认设置。": "Settings could not be loaded. Defaults are in use.",
        "无法保存设置，请检查本地存储权限。": "Could not save settings. Check local storage permissions.",
        "回到选点": "Recenter", "目标位置地图": "Target location map", "坐标": "Coordinates",
        "纬度": "Latitude", "经度": "Longitude", "目标纬度": "Target latitude", "目标经度": "Target longitude",
        "−90 至 90": "−90 to 90", "−180 至 180": "−180 to 180", "WGS84 · 十进制度": "WGS84 · Decimal degrees",
        "坐标系": "Coordinate system", "WGS84（GPS）": "WGS84 (GPS)", "GCJ-02（国内地图）": "GCJ-02 (China)",
        "请选择坐标系": "Select coordinate system", "正在确认地图坐标系…": "Checking map coordinate system…",
        "无法确认地图坐标系，请重试选点或选择已知坐标系。": "Map coordinates could not be confirmed. Select again or choose a known coordinate system.",
        "地图暂不可用，仍可使用已知坐标修改定位。": "Map unavailable. Known coordinates can still be applied.",
        "旧收藏未记录坐标系，请选择坐标系或重新从地图选点。": "This older favorite has no coordinate system. Choose one or select the location again on the map.",
        "请先确认坐标系。": "Confirm the coordinate system first.",
        "用于手工输入经纬度；地图选点、搜索和收藏保留各自的坐标系。": "Used for typed coordinates. Map selections, searches, and favorites retain their coordinate systems.",
        "确认当前坐标系": "Confirm for Current Location",
        "设置坐标系": "Set Coordinate System",
        "无法确认地图坐标系，请重试选点或在设置中确认。": "Map coordinates could not be confirmed. Select again or confirm in Settings.",
        "旧收藏未记录坐标系，请在设置中确认或重新从地图选点。": "This older favorite has no coordinate system. Confirm it in Settings or select the location again on the map.",
        "修改定位": "Change Location", "还原定位": "Restore Location", "取消": "Cancel", "覆盖": "Replace",
        "随机偏移": "Random Offset", "随机范围": "Random range", "%d 米": "%d m",
        "以选点为中心，在 %d × %d 米范围内随机；每次修改定位重新取点。": "Pick a random point in a %d × %d m square centered on the selection each time you change location.",
        "上次随机发送（WGS84）": "Last random request (WGS84)",
        "收藏": "Favorites", "保存收藏": "Save Favorite", "保存": "Save", "删除": "Delete", "修改名称": "Rename", "删除收藏": "Delete Favorite",
        "修改收藏名称": "Rename Favorite", "收藏名称": "Favorite name", "收藏当前位置": "Save This Location",
        "取消当前位置收藏": "Remove This Favorite", "取消收藏": "Remove Favorite", "位置 %d": "Location %d",
        "收藏“%@”的操作": "Actions for %@", "最多收藏 5 个位置": "You can save up to 5 favorites",
        "是否覆盖最老的收藏“%@”？": "Replace the oldest favorite, “%@”?",
        "选好位置后，点击坐标旁的 ☆ 收藏。": "Choose a location, then click ☆ to save it.",
        "选用后，点击修改定位发送至手机": "Select it, then click Change Location to send it to your phone.",
        "保持 USB 连接。还原后请在手机地图确认位置。": "Keep USB connected. Confirm the restored location on your phone.",
        "搜索城市、地址或地点": "Search cities, addresses, or places", "搜索地点": "Search places",
        "清除搜索": "Clear search", "地点联想": "Suggestions", "搜索结果": "Search results", "地点": "Place",
        "连接诊断": "Connection Diagnostics", "暂无诊断记录": "No diagnostic entries yet", "导出诊断": "Export Diagnostics",
        "界面预览 · 不会操作手机": "Preview · No device changes", "界面预览": "Preview", "真实设备": "Real device",
        "地图选点": "Map selection", "经纬度选点": "Coordinate selection", "尚未选择位置": "No location selected",
        "正在处理": "Working", "等待 iPhone": "Waiting for iPhone", "发现设备": "Finding device",
        "检查信任与开发者模式": "Checking trust and Developer Mode", "检查开发组件": "Checking developer components",
        "准备开发组件": "Preparing developer components", "加载开发组件": "Loading developer components",
        "建立连接": "Connecting", "连接定位服务": "Connecting to location service", "清理上次会话": "Cleaning up previous session",
        "已就绪": "Ready", "定位指令已发送": "Location request sent", "正在停止": "Restoring location",
        "手机已连接": "iPhone Connected", "定位修改已发送": "Location Change Sent",
        "连接暂不可用，正在重试": "Connection unavailable, retrying", "定位状态待确认": "Check location on phone",
        "定位状态待确认，请在手机地图核对位置。": "Location status is uncertain. Check the location in Maps on your phone.",
        "连接 iPhone 后会自动准备，请保持手机解锁。": "Connect your iPhone to set up automatically. Keep it unlocked.",
        "无法读取收藏，请检查本地收藏文件。": "Could not load favorites. Check the local favorites file.",
        "界面预览使用模拟设备，不会连接或修改 iPhone。": "Preview uses a simulated device and does not change your iPhone.",
        "后台已退出。若此前正在模拟，请在手机确认位置状态。": "The backend has stopped. Check the location on your phone.",
        "连接已断开，请在手机确认位置状态。": "Disconnected. Check the location on your phone.",
        "等待 iPhone 重新接入，连接后会先清理上次会话。": "Waiting for iPhone. The previous session will be cleared on reconnection.",
        "等待 iPhone 接入，请解锁手机并确认信任此电脑。": "Connect and unlock your iPhone, then trust this computer.",
        "正在自动连接 iPhone，请保持手机解锁。": "Connecting automatically. Keep your iPhone unlocked.",
        "设备已就绪。选择目标位置后，点击修改定位。": "Ready. Choose a location, then click Change Location.",
        "请检查手机状态，重新插入 iPhone 后自动重试。": "Check your iPhone and reconnect the cable to retry.",
        "请解锁 iPhone 并确认信任，稍后将自动重试。": "Unlock your iPhone and trust this computer. Retrying shortly.",
        "预览：模拟指令已发送，未操作真实设备。": "Preview: simulated request sent. No real device changes.",
        "请在手机地图核对实际位置。": "Check the location in Maps on your phone.",
        "请在手机地图核对实际位置": "Check the location in Maps on your phone.", "已发送设置请求": "Location request sent",
        "预览：模拟停止请求完成。": "Preview: restore request completed.", "请在手机确认恢复。": "Confirm restoration on your phone.",
        "清除请求已发送，恢复结果待手机确认": "Restore request sent. Confirm restoration on your phone.",
        "清除请求已发送，请在手机地图确认恢复": "Restore request sent. Confirm restoration in Maps on your phone.",
        "请重连后清理，并在手机确认位置。": "Reconnect to clear the session, then check your phone.",
        "设备会话已断开。": "Device session disconnected.",
        "操作已取消。重新插入 iPhone 后会自动连接。": "Cancelled. Reconnect your iPhone to connect automatically.",
        "请输入有效经纬度：纬度 −90 至 90，经度 −180 至 180。": "Enter valid coordinates: latitude −90 to 90, longitude −180 to 180.",
        "请先选择位置或输入有效经纬度。": "Choose a location or enter valid coordinates first.",
        "最多收藏 5 个位置。": "You can save up to 5 favorites.", "请填写收藏名称。": "Enter a favorite name.",
        "收藏已不存在。": "This favorite no longer exists.",
        "无法保存收藏，请检查本地存储权限。": "Could not save favorites. Check local storage permissions.",
        "没有找到地点，可以直接输入经纬度。": "No places found. You can enter coordinates instead.",
        "搜索暂不可用，仍可输入经纬度选点。": "Search is unavailable. You can still enter coordinates.",
        "虚拟定位诊断.txt": "Virtual Location Diagnostics.txt", "模式": "Mode", "状态": "Status",
        "无法保存诊断文件。": "Could not save the diagnostics file.",
        "未找到项目目录，请重新构建应用。": "Project directory not found. Rebuild the app.",
        "缺少运行环境，请先在项目目录执行 sh scripts/setup.sh。": "Runtime missing. Run sh scripts/setup.sh in the project directory.",
        "后台已退出；手机定位状态需在设备上确认。": "The backend stopped. Check the location on your phone.",
        "后台响应超出限制。": "Backend response exceeded the size limit.", "操作失败": "Operation failed",
        "后台尚未启动。": "The backend is not running.", "无法向后台发送请求。": "Could not send the backend request.",
        "后台响应超时，请断开后重试。": "Backend request timed out. Reconnect your iPhone to retry.", "后台已停止。": "Backend stopped.",
        "开发镜像下载超出限制": "Developer image download exceeded the size limit.",
        "开发镜像版本与固定依赖不一致": "Developer image version does not match the pinned dependency.",
        "未找到所选 USB 设备，请重新连接并刷新": "USB device not found. Reconnect your iPhone.",
        "此验证版本仅启用 iOS 26，请先做兼容性评估": "This version currently supports iOS 26 only.",
        "请在手机隐私与安全性中开启开发者模式并按提示重启": "Enable Developer Mode in Privacy & Security on your phone, then restart as prompted.",
        "首次准备需发送设备标识到 Apple，请明确允许后重试": "Apple signing requires permission to send device identifiers. Authorize it before retrying.",
        "开发镜像下载或校验失败，请检查网络后重试": "Developer image download or verification failed. Check your network.",
        "Apple 未返回成功的开发镜像签名，请稍后重试": "Apple did not return a valid developer image signature. Try again later.",
        "坐标必须为数值": "Coordinates must be numbers.", "坐标超出范围或不是有限数": "Coordinates are out of range or not finite.",
        "设备标识无效": "Invalid device identifier.", "请先断开当前会话": "Disconnect the current session first.",
        "设备尚未就绪": "The device is not ready.", "请先连接设备，再发送清除请求": "Connect the device before restoring its location.",
        "连接已中断，手机定位状态待确认": "Connection lost. Check the location on your phone.",
        "操作超时，请解锁手机并检查连接后重试": "Operation timed out. Unlock your phone and check the connection.",
        "设备操作失败，请检查连接、信任与开发者模式": "Device operation failed. Check connection, trust, and Developer Mode.",
        "会话已失效，请重新连接": "Session expired. Reconnect your iPhone.", "不支持的命令": "Unsupported command.", "已取消": "Cancelled",
        "已有本项目的设备会话正在运行，请先退出该会话": "Another device session is running. Close it before reconnecting.",
        "请求过长": "Request too long.", "缺少请求标识": "Missing request identifier.", "请求标识无效": "Invalid request identifier.",
        "请勿重复提交同一请求": "Do not submit the same request twice.", "请重启后台进程": "Restart the backend.",
        "当前操作尚未完成，可取消后重试": "An operation is in progress. Cancel it before retrying.",
    ]
}
