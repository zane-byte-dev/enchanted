//
//  AppLanguage.swift
//  Enchanted
//
//  In-app UI language override. Writes to the standard `AppleLanguages`
//  UserDefaults key so the change persists across launches.
//

import Foundation

enum AppLanguage: String, Identifiable, CaseIterable {
    /// Follow the system language order.
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var toString: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// Language code stored in `AppleLanguages`, or nil to defer to system.
    var localeCode: String? {
        self == .system ? nil : rawValue
    }

    /// Current effective selection derived from `AppleLanguages`.
    static var current: AppLanguage {
        guard let codes = UserDefaults.standard.stringArray(forKey: "AppleLanguages"),
              let first = codes.first else {
            return .system
        }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// Apply the selection. Returns true if a restart is needed to take effect.
    func apply() {
        switch localeCode {
        case .some(let code):
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        case .none:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}
