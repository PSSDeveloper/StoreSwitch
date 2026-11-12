import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "interfaceLanguage"
    static let preferred = Bundle.preferredLocalizations(from: allCases.map(\.rawValue))
        .first.flatMap(Self.init(rawValue:)) ?? .simplifiedChinese

    static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? preferred
    }

    var name: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    func text(_ resource: LocalizedStringResource) -> String {
        var localized = resource
        localized.locale = locale
        return String(localized: localized)
    }
}

func tr(_ resource: LocalizedStringResource) -> String {
    AppLanguage.current.text(resource)
}
