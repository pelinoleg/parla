import AppKit
import Carbon.HIToolbox
import Combine

enum Language: String, CaseIterable, Identifiable, Codable {
    case ro, ru, es, ca, en, uk, fr, de, it, pt

    var id: String { rawValue }

    /// Name used in prompts (English is what models understand best).
    var englishName: String {
        switch self {
        case .ro: "Romanian"
        case .ru: "Russian"
        case .es: "Spanish (Spain)"
        case .ca: "Catalan"
        case .en: "English"
        case .uk: "Ukrainian"
        case .fr: "French"
        case .de: "German"
        case .it: "Italian"
        case .pt: "Portuguese"
        }
    }

    var nativeName: String {
        switch self {
        case .ro: "Română"
        case .ru: "Русский"
        case .es: "Español"
        case .ca: "Català"
        case .en: "English"
        case .uk: "Українська"
        case .fr: "Français"
        case .de: "Deutsch"
        case .it: "Italiano"
        case .pt: "Português"
        }
    }

    var flag: String {
        switch self {
        case .ro: "🇷🇴"
        case .ru: "🇷🇺"
        case .es: "🇪🇸"
        case .ca: "🏴󠁥󠁳󠁣󠁴󠁿"
        case .en: "🇬🇧"
        case .uk: "🇺🇦"
        case .fr: "🇫🇷"
        case .de: "🇩🇪"
        case .it: "🇮🇹"
        case .pt: "🇵🇹"
        }
    }

    var code: String { rawValue.uppercased() }

    var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }
}

enum ProviderID: String, CaseIterable, Identifiable, Codable {
    case claude, openai, deepseek, apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .apple: "Apple (offline)"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: "claude-opus-5-5"
        case .openai: "gpt-5-mini"
        case .deepseek: "deepseek-chat"
        case .apple: ""
        }
    }

    var needsKey: Bool { self != .apple }

    var keyPrefix: String {
        switch self {
        case .claude: "sk-ant-…"
        case .openai, .deepseek: "sk-…"
        case .apple: ""
        }
    }

    var keyURL: URL? {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
        case .apple: nil
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        default: break
        }
        // Resolve through the current keyboard layout, falling back to ASCII layout.
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
                return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                      OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
            }
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "#\(code)"
    }

    /// Converts NSEvent modifier flags to the Carbon mask RegisterEventHotKey expects.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var target: Language { didSet { d.set(target.rawValue, forKey: "target") } }
    /// Used when the selected text is already in the target language.
    @Published var alternate: Language { didSet { d.set(alternate.rawValue, forKey: "alternate") } }
    /// The language the user writes their own replies in.
    @Published var myLanguage: Language { didSet { d.set(myLanguage.rawValue, forKey: "myLanguage") } }

    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var shortcut: Shortcut { didSet { d.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") } }
    @Published var doubleCopyEnabled: Bool { didSet { d.set(doubleCopyEnabled, forKey: "doubleCopyEnabled") } }
    @Published var selectionButtonEnabled: Bool { didSet { d.set(selectionButtonEnabled, forKey: "selectionButtonEnabled") } }
    @Published var servicesEnabled: Bool { didSet { d.set(servicesEnabled, forKey: "servicesEnabled") } }

    @Published var providerOrder: [ProviderID] { didSet { d.set(providerOrder.map(\.rawValue), forKey: "providerOrder") } }
    @Published var disabledProviders: Set<ProviderID> {
        didSet { d.set(disabledProviders.map(\.rawValue), forKey: "disabledProviders") }
    }
    @Published var models: [String: String] { didSet { d.set(models, forKey: "models") } }

    private init() {
        target = Language(rawValue: d.string(forKey: "target") ?? "") ?? .ro
        alternate = Language(rawValue: d.string(forKey: "alternate") ?? "") ?? .es
        myLanguage = Language(rawValue: d.string(forKey: "myLanguage") ?? "") ?? .ru
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        shortcut = (d.data(forKey: "shortcut")).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        doubleCopyEnabled = d.object(forKey: "doubleCopyEnabled") as? Bool ?? true
        selectionButtonEnabled = d.object(forKey: "selectionButtonEnabled") as? Bool ?? true
        servicesEnabled = d.object(forKey: "servicesEnabled") as? Bool ?? true

        var order = (d.stringArray(forKey: "providerOrder") ?? []).compactMap(ProviderID.init)
        for p in ProviderID.allCases where !order.contains(p) { order.append(p) }
        providerOrder = order
        disabledProviders = Set((d.stringArray(forKey: "disabledProviders") ?? []).compactMap(ProviderID.init))
        models = d.dictionary(forKey: "models") as? [String: String] ?? [:]
    }

    func model(for p: ProviderID) -> String {
        let m = models[p.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? p.defaultModel : m
    }

    /// Providers that will actually be tried, in order.
    var activeProviders: [ProviderID] {
        providerOrder.filter { !disabledProviders.contains($0) && (!$0.needsKey || Keychain.get($0.rawValue) != nil) }
    }
}
