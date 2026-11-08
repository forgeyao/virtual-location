import SwiftUI

private typealias SettingsState<Value> = SwiftUI.State<Value>

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @SettingsState private var diagnosticsExpanded = false

    init(model: AppModel, diagnosticsExpanded: Bool = false) {
        self.model = model
        self.preferences = model.preferences
        _diagnosticsExpanded = SwiftUI.State<Bool>(initialValue: diagnosticsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(preferences.text("外观")).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker(preferences.text("外观"), selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(preferences.text(appearance.title)).tag(appearance)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                    .id(preferences.appearance)
                    .transaction { $0.animation = nil }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(preferences.text("语言")).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker(preferences.text("语言"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(preferences.text("坐标系")).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker(preferences.text("坐标系"), selection: $preferences.coordinateSystem) {
                    Text(preferences.text(CoordinateSystem.gcj02.title)).tag(CoordinateSystem.gcj02)
                    Text(preferences.text(CoordinateSystem.wgs84.title)).tag(CoordinateSystem.wgs84)
                }.pickerStyle(.segmented).labelsHidden()
                Text(preferences.text("用于手工输入经纬度；地图选点、搜索和收藏保留各自的坐标系。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.coordinateSystem == .unresolved, model.coordinate != nil {
                    Button(preferences.text("确认当前坐标系")) {
                        model.setInputCoordinateSystem(preferences.coordinateSystem)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(preferences.text("设置自动保存并立即生效。"))
                .font(.caption).foregroundStyle(.secondary)
            if preferences.requiresRelaunch {
                Text(preferences.text("菜单栏应用名将在重新打开应用后更新。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = preferences.error {
                Text(preferences.text(error)).font(.caption).foregroundStyle(.red)
            }
            Divider()
            DisclosureGroup(preferences.text("连接诊断"), isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView {
                        Text(model.log.isEmpty ? preferences.text("暂无诊断记录") : model.localizedLog.suffix(10).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 150)
                    HStack {
                        Spacer()
                        Button(preferences.text("导出诊断")) { model.exportDiagnostics() }
                    }
                }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(24).frame(width: 400, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: preferences.language.rawValue))
    }
}
