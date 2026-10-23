import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reading the selected text of the frontmost app and pasting back into it.
enum Selection {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Selected text via Accessibility — instant and leaves the clipboard alone.
    static func axSelectedText() -> String? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else {
            enableWebAccessibilityForFrontApp()
            return nil
        }
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }
        return nil
    }

    /// Chrome and Electron apps only expose their text tree when an assistive app asks for it.
    private static var enabledPIDs = Set<pid_t>()
    static func enableWebAccessibilityForFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication, !enabledPIDs.contains(app.processIdentifier) else { return }
        enabledPIDs.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Fallback: press ⌘C in the front app, read the clipboard, then put the old clipboard back.
    static func copySelection(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postKey(UInt16(kVK_ANSI_C), flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let text = pb.changeCount != before ? pb.string(forType: .string) : nil
            restore(saved, to: pb)
            completion(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil)
        }
    }

    /// Best effort: AX first, ⌘C second.
    static func grab(completion: @escaping (String?) -> Void) {
        if let text = axSelectedText() {
            completion(text)
        } else {
            copySelection(completion: completion)
        }
    }

    /// Replaces the current selection in the front app with `text`, keeping the user's clipboard.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restore(saved, to: pb) }
        }
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Helpers

    private static func postKey(_ key: UInt16, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { dict[type] = data } }
            return dict
        }
    }

    private static func restore(_ snapshot: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        let items = snapshot.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
