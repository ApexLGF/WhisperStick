import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: VoiceInputManager
    @EnvironmentObject var toastCenter: FallbackToastCenter
    @EnvironmentObject var selectionStore: SessionSelectionStore
    @EnvironmentObject var hookStore: ClaudeHookSessionStore
    @EnvironmentObject var languageSettings: AppLanguageSettings
    @State private var selectedTab: Int
    @State private var selectedSettingsCategory: SettingsCategory? = UITestFlags.forcedSettingsCategory ?? .general
    var onTabChanged: (Int) -> Void = { _ in }

    init(initialTab: Int = 0, onTabChanged: @escaping (Int) -> Void = { _ in }) {
        _selectedTab = State(initialValue: initialTab)
        self.onTabChanged = onTabChanged
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            StatusTab(selectedTab: $selectedTab, settingsCategory: $selectedSettingsCategory)
                .tabItem { Label(AppL10n.tr("状态"), systemImage: "chart.bar.fill") }
                .tag(0)

            DeviceTab()
                .tabItem { Label(AppL10n.tr("设备"), systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)

            HistoryTab()
                .tabItem { Label(AppL10n.tr("历史"), systemImage: "clock.arrow.circlepath") }
                .tag(2)

            SettingsTab(selection: $selectedSettingsCategory)
                .tabItem { Label(AppL10n.tr("设置"), systemImage: "gearshape") }
                .tag(4)
        }
        .id(languageSettings.revision)
        .onAppear { onTabChanged(selectedTab) }
        .onChange(of: selectedTab) { _, tab in
            ContentView.persistLastTabTag(tab)
            onTabChanged(tab)
        }
        .onChange(of: languageSettings.selectedLanguage) { _, _ in
            // Device UI follows the Mac App language; refresh both persistent
            // configuration and an action menu that may currently be visible.
            QuickVibeHostApp.pushV5Config(ble: manager.bleManager)
            manager.bleManager?.refreshActiveActionMode(language: .selected)
        }
        .overlay(alignment: .top) {
            if let toast = toastCenter.current {
                FallbackToastView(toast: toast) { toastCenter.dismiss() }
                    .padding(.top, 14)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: toastCenter.current)
    }

    static let lastTabDefaultsKey = "lastSelectedMainTab"
    private static let validTabTags: Set<Int> = [0, 1, 2, 4]

    static func storedLastTabTag(_ defaults: UserDefaults = .standard) -> Int? {
        let tab = defaults.object(forKey: lastTabDefaultsKey) as? Int
        return tab.flatMap { validTabTags.contains($0) ? $0 : nil }
    }

    static func persistLastTabTag(_ tab: Int, defaults: UserDefaults = .standard) {
        guard validTabTags.contains(tab) else { return }
        defaults.set(tab, forKey: lastTabDefaultsKey)
    }

    static func initialTabTag(forcedTab: Int?, storedLastTabTag: Int?) -> Int {
        if let forcedTab, validTabTags.contains(forcedTab) {
            return forcedTab
        }
        if let storedLastTabTag, validTabTags.contains(storedLastTabTag) {
            return storedLastTabTag
        }
        // First launch has no prior preference. Lead with device setup, but do
        // not let asynchronous BLE reconnection override a returning user's tab.
        return 1
    }
}
