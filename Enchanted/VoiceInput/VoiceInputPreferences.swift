#if os(macOS)
import Foundation

enum VoiceInputPreferences {
    static let engineKey = "voiceInputRecognitionEngine"
    static let localeKey = "voiceInputLocale"
    static let onDeviceOnlyKey = "voiceInputOnDeviceOnly"
    static let aiCorrectionKey = "voiceInputAICorrection"
    static let removeTrailingPeriodKey = "voiceInputRemoveTrailingPeriod"
    static let dictionaryKey = "voiceInputDictionary"

    static var locale: Locale {
        let identifier = UserDefaults.standard.string(forKey: localeKey) ?? "auto"
        return identifier == "auto" ? .current : Locale(identifier: identifier)
    }

    static var onDeviceOnly: Bool {
        UserDefaults.standard.bool(forKey: onDeviceOnlyKey)
    }

    static var senseVoiceLanguage: String {
        switch UserDefaults.standard.string(forKey: localeKey) ?? "auto" {
        case "zh-CN", "zh-TW": return "zh"
        case "yue-Hant-HK": return "yue"
        case "en-US": return "en"
        case "ja-JP": return "ja"
        case "ko-KR": return "ko"
        default: return "auto"
        }
    }

    static var aiCorrectionEnabled: Bool {
        UserDefaults.standard.bool(forKey: aiCorrectionKey)
    }

    static var removeTrailingPeriod: Bool {
        UserDefaults.standard.bool(forKey: removeTrailingPeriodKey)
    }

    static var replacements: [(source: String, target: String)] {
        let raw = UserDefaults.standard.string(forKey: dictionaryKey) ?? ""
        return raw.split(whereSeparator: { $0.isNewline }).compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            for separator in ["=>", "→", "="] {
                let parts = value.components(separatedBy: separator)
                if parts.count == 2 {
                    let source = parts[0].trimmingCharacters(in: .whitespaces)
                    let target = parts[1].trimmingCharacters(in: .whitespaces)
                    if !source.isEmpty, !target.isEmpty {
                        return (source, target)
                    }
                }
            }
            return nil
        }
    }

    static var contextualTerms: [String] {
        replacements.flatMap { [$0.source, $0.target] }
    }
}
#endif
