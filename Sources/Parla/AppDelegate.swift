import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let popup = PopupController()
    private let services = ServicesProvider()
    private var triggers: Triggers?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Parla")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        popup.onSettings = { [weak self] in self?.openSettings() }
        triggers = Triggers { [weak self] text in
            Task { @MainActor in self?.popup.show(text: text) }
        }
        services.onText = { [weak self] text in
            Task { @MainActor in self?.popup.show(text: text) }
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        // First run: nothing to translate with, or no permission yet — show Settings.
        if !Selection.isTrusted || Settings.shared.activeProviders.allSatisfy({ $0 == .apple }) {
            openSettings()
        }
    }

    // Rebuilt on every open so the permission warning and shortcut are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        let translate = NSMenuItem(title: "Translate…", action: #selector(openEmpty), keyEquivalent: "")
        translate.target = self
        if s.hotkeyEnabled { translate.toolTip = s.shortcut.display }
        menu.addItem(translate)

        let clipboard = NSMenuItem(title: "Translate Clipboard", action: #selector(translateClipboard), keyEquivalent: "")
        clipboard.target = self
        menu.addItem(clipboard)

        if !Selection.isTrusted {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "⚠︎ Allow Accessibility access…", action: #selector(openSettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openEmpty() {
        popup.show(text: nil)
    }

    @objc private func translateClipboard() {
        popup.show(text: NSPasteboard.general.string(forType: .string))
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Parla Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
