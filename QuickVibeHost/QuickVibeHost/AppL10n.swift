import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        }
    }
}

final class AppLanguageSettings: ObservableObject {
    static let userDefaultsKey = "appLanguageOverride"

    @Published var selectedLanguage: AppLanguage {
        didSet {
            guard selectedLanguage != oldValue else { return }
            if selectedLanguage == .system {
                defaults.set("", forKey: Self.userDefaultsKey)
            } else {
                defaults.set(selectedLanguage.rawValue, forKey: Self.userDefaultsKey)
            }
            revision += 1
        }
    }

    @Published private(set) var revision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedLanguage = AppLanguage(rawValue: defaults.string(forKey: Self.userDefaultsKey) ?? "") ?? .system
    }
}

enum AppL10n {
    static func tr(_ value: String.LocalizationValue) -> String {
        if let bundle = overrideBundle() {
            return String(localized: value, bundle: bundle)
        }
        return String(localized: value)
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        let format = localizedString(for: key)
        return String(format: format, locale: Locale.current, arguments: args)
    }

    private static func localizedString(for key: String) -> String {
        if let bundle = overrideBundle() {
            return NSLocalizedString(key, bundle: bundle, comment: "")
        }
        return NSLocalizedString(key, comment: "")
    }

    private static func overrideBundle() -> Bundle? {
        let raw = UserDefaults.standard.string(forKey: AppLanguageSettings.userDefaultsKey) ?? ""
        guard !raw.isEmpty else { return nil }
        guard AppLanguage(rawValue: raw) != nil else { return nil }
        guard let path = Bundle.main.path(forResource: raw, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
