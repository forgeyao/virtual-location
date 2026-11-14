import SwiftUI
import MapKit

// Select the property wrapper on CLT SDKs that omit the newer State macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var suggestions: PlaceSuggestions
    @Environment(\.colorScheme) private var colorScheme
    private let onOpenSettings: () -> Void
    @ViewState private var showFavoriteEditor = false
    @ViewState private var favoriteName = ""
    @ViewState private var showStatusDetails = false
    @ViewState private var editingFavorite: FavoriteLocation?

    init(model: AppModel, onOpenSettings: @escaping () -> Void = {}) {
        self.model = model
        self.preferences = model.preferences
        self.suggestions = model.suggestions
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 320)
            Divider()
            MapReader { proxy in
                Map(position: $model.position) {
                    if let point = model.point {
                        Annotation(model.displayPlaceName, coordinate: point, anchor: .bottom) {
                            LocationPin().accessibilityLabel(model.displayPlaceName)
                        }
                    }
                }
                .mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
                .onTapGesture { location in
                    if let coordinate = proxy.convert(location, from: .local) {
                        model.selectMapPoint(coordinate)
                    }
                }
                .accessibilityLabel(tr("目标位置地图"))
            }
            .overlay(alignment: .top) {
                searchPanel.frame(width: 360).padding(.top, 16)
            }
            .overlay(alignment: .topLeading) {
                Button { model.returnToSelection() } label: {
                    Label(tr("回到选点"), systemImage: "scope").padding(.horizontal, 12).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .disabled(model.deviceCoordinate == nil)
                .padding(16)
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: preferences.language.rawValue))
        .sheet(item: $editingFavorite) { favorite in renameEditor(favorite) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.preview {
                        Label(tr("界面预览 · 不会操作手机"), systemImage: "eye")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    coordinateSection
                    Divider()
                    favoritesSection
                }.padding(20)
            }
            HStack(alignment: .top, spacing: 12) {
                statusBadge
                Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(tr("设置")).accessibilityLabel(tr("设置"))
                    .padding(.top, 2)
            }
                .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    private var coordinateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("坐标", icon: "mappin.and.ellipse")
                Spacer()
                Button {
                    if let favorite = model.currentFavorite {
                        model.removeFavorite(favorite)
                    } else {
                        favoriteName = ["尚未选择位置", "地图选点", "经纬度选点"].contains(model.placeName)
                            ? preferences.format("位置 %d", model.favorites.count + 1) : model.displayPlaceName
                        showFavoriteEditor = true
                    }
                } label: {
                    Image(systemName: model.currentFavorite == nil ? "star" : "star.fill")
                        .foregroundStyle(model.currentFavorite == nil ? Color.secondary : .teal)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(tr(model.currentFavorite == nil ? "收藏当前位置" : "取消当前位置收藏"))
                .help(tr(model.currentFavorite != nil ? "取消收藏" : "收藏当前位置"))
                .disabled(model.deviceCoordinate == nil)
                .popover(isPresented: $showFavoriteEditor) { favoriteEditor }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text(tr("纬度"))
                    TextField(tr("−90 至 90"), text: $model.latitude).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(tr("目标纬度"))
                }
                GridRow {
                    Text(tr("经度"))
                    TextField(tr("−180 至 180"), text: $model.longitude).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(tr("目标经度"))
                }
            }
            if !model.coordinateMessage.isEmpty {
                Text(tr(model.coordinateMessage)).font(.caption).foregroundStyle(.secondary)
                if model.coordinateSystem == .unresolved {
                    Button(tr("设置坐标系"), action: onOpenSettings).buttonStyle(.link)
                }
            }
            randomLocationOptions
            Button { model.apply() } label: {
                Label(tr("修改定位"), systemImage: "location.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(.teal).controlSize(.large).disabled(!model.canApply)
            Button { model.stop() } label: {
                Label(tr("还原定位"), systemImage: "arrow.uturn.backward.circle").frame(maxWidth: .infinity)
            }.controlSize(.large).disabled(!model.connected)
            if let sent = model.lastRandomizedCoordinate {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("上次随机发送（WGS84）"))
                    Text(String(format: "%.7f, %.7f", locale: Locale(identifier: "en_US_POSIX"), sent.latitude, sent.longitude))
                        .monospacedDigit().textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text(tr("保持 USB 连接。还原后请在手机地图确认位置。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var randomLocationOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(tr("随机偏移"), isOn: $preferences.randomLocationEnabled)
                .toggleStyle(.switch).controlSize(.small)
            if preferences.randomLocationEnabled {
                Picker(tr("随机范围"), selection: $preferences.randomLocationRange) {
                    ForEach(RandomLocationRange.allCases, id: \.self) { range in
                        Text(preferences.format("%d 米", range.rawValue)).tag(range)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                Text(preferences.format("以选点为中心，在 %d × %d 米范围内随机；每次修改定位重新取点。",
                                        preferences.randomLocationRange.rawValue, preferences.randomLocationRange.rawValue))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(model.busy)
    }

    private var statusColor: Color {
        if model.statusIsError { return .red }
        switch model.state {
        case "ready": return .green
        case "simulating": return .teal
        case "retrying": return .yellow
        default: return .primary
        }
    }

    private var statusBadge: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showStatusDetails.toggle() } label: {
                HStack(alignment: .top, spacing: 7) {
                    Text(model.statusText).font(.callout.weight(.medium))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(tr(model.message))
            .popover(isPresented: $showStatusDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.statusText).font(.headline)
                        .foregroundStyle(statusColor)
                    Text(tr(model.message)).font(.callout).textSelection(.enabled)
                }.padding(16).frame(width: 260, alignment: .leading)
            }
            if model.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.mini)
                    Text(String(format: preferences.language == .chinese ? "%.1f 秒" : "%.1f s", model.elapsed))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(tr("取消")) { model.cancel() }.buttonStyle(.borderless)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("收藏", icon: "star")
                Spacer()
                Text("\(model.favorites.count)/\(FavoriteStore.limit)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if model.favorites.isEmpty {
                Text(tr("选好位置后，点击坐标旁的 ☆ 收藏。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.favorites) { favorite in
                HStack(spacing: 8) {
                    Button { model.selectFavorite(favorite) } label: {
                        Text(favorite.name).font(.callout).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help("\(favorite.name) · \(favorite.coordinateText)\n\(tr("选用后，点击修改定位发送至手机"))")
                        .accessibilityValue(favorite.coordinateText)
                    Menu {
                        Button(tr("修改名称")) {
                            favoriteName = favorite.name
                            model.favoritesError = nil
                            editingFavorite = favorite
                        }
                        Button(tr("删除收藏"), role: .destructive) { model.removeFavorite(favorite) }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(preferences.format("收藏“%@”的操作", favorite.name))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(model.currentFavorite?.id == favorite.id ? Color.teal.opacity(0.10) : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = model.favoritesError {
                Text(tr(error)).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var favoriteEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("收藏当前位置")).font(.headline)
            TextField(tr("收藏名称"), text: $favoriteName)
                .textFieldStyle(.roundedBorder).onSubmit { saveFavorite() }
            if let error = model.favoritesError { Text(tr(error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(tr("取消")) { showFavoriteEditor = false }
                Button(tr("保存收藏")) { saveFavorite() }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).frame(width: 260)
    }

    private func saveFavorite() {
        if model.currentFavorite == nil && model.favorites.count >= FavoriteStore.limit {
            showFavoriteEditor = false
            let name = favoriteName
            DispatchQueue.main.async {
                AppDialogs.confirmReplacement(oldestName: model.favorites.last?.name ?? "", preferences: preferences) { confirmed in
                    if confirmed { _ = model.addFavorite(name: name, replacingOldest: true) }
                }
            }
        } else if model.addFavorite(name: favoriteName) {
            showFavoriteEditor = false
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.searchPlaces() } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.teal)
                }.buttonStyle(.plain).help(tr("搜索地点"))
                TextField(tr("搜索城市、地址或地点"), text: $model.query)
                    .textFieldStyle(.plain).onSubmit { model.searchPlaces() }
                    .onExitCommand { model.dismissSearchResults() }
                if model.searching { ProgressView().controlSize(.small) }
                if !model.query.isEmpty {
                    Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help(tr("清除搜索")).accessibilityLabel(tr("清除搜索"))
                }
            }.padding(14)
            if !model.searchMessage.isEmpty {
                Text(tr(model.searchMessage)).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            if !model.results.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.offset) { _, item in
                            Button {
                                model.selectSearchResult(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? tr("地点")).font(.callout).lineLimit(1)
                                    Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: CGFloat(min(model.results.count, 5)) * 54)
            } else if !suggestions.results.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.results.enumerated()), id: \.offset) { _, completion in
                            Button { model.selectSuggestion(completion) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(completion.title).font(.callout).lineLimit(1)
                                    if !completion.subtitle.isEmpty {
                                        Text(completion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: CGFloat(min(suggestions.results.count, 5)) * 54)
                    .accessibilityLabel(tr("地点联想"))
            }
        }
        .background(colorScheme == .dark ? Color(red: 0.22, green: 0.27, blue: 0.30) : .white,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.teal.opacity(colorScheme == .dark ? 0.85 : 0.5), lineWidth: 1.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.16), radius: 14, y: 5)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(tr(title), systemImage: icon).font(.headline)
    }

    private func tr(_ text: String) -> String { preferences.text(text) }

    private func renameEditor(_ favorite: FavoriteLocation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("修改收藏名称")).font(.headline)
            TextField(tr("收藏名称"), text: $favoriteName).textFieldStyle(.roundedBorder)
            if let error = model.favoritesError { Text(tr(error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(tr("取消")) { editingFavorite = nil }.keyboardShortcut(.cancelAction)
                Button(tr("保存")) {
                    if model.renameFavorite(favorite, name: favoriteName) { editingFavorite = nil }
                }.keyboardShortcut(.defaultAction)
                    .disabled(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 300)
    }
}
