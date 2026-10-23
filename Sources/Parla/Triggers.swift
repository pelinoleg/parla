import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Wires up every way to start a translation; each one can be switched off in Settings.
final class Triggers {
    private let settings = Settings.shared
    private let onText: (String?) -> Void
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var mouseMonitors: [Any] = []
    private var bag = Set<AnyCancellable>()

    private var lastCopy = Date.distantPast
    private var mouseDownPoint = NSPoint.zero
    private let button = SelectionButton()

    /// `onText(nil)` means "open the popup with an empty input".
    init(onText: @escaping (String?) -> Void) {
        self.onText = onText
        button.onClick = { [weak self] text in self?.onText(text) }

        settings.$hotkeyEnabled.combineLatest(settings.$shortcut)
            .sink { [weak self] enabled, shortcut in self?.setHotKey(enabled ? shortcut : nil) }
            .store(in: &bag)
        settings.$doubleCopyEnabled
            .sink { [weak self] on in self?.setDoubleCopy(on) }
            .store(in: &bag)
        settings.$selectionButtonEnabled
            .sink { [weak self] on in self?.setSelectionButton(on) }
            .store(in: &bag)
    }

    // MARK: Hotkey

    private func setHotKey(_ shortcut: Shortcut?) {
        hotKey = nil
        guard let shortcut else { return }
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.button.hide()
            Selection.grab { self?.onText($0) }
        }
    }

    // MARK: Double ⌘C

    private func setDoubleCopy(_ on: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard on else { return }
        // Global key monitoring needs Accessibility permission; it silently gets nothing without it.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            self.button.hide()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == UInt16(kVK_ANSI_C), flags == .command, !event.isARepeat else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastCopy) < 0.45 {
                self.lastCopy = .distantPast
                // Let the second ⌘C land in the clipboard first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.onText(NSPasteboard.general.string(forType: .string))
                }
            } else {
                self.lastCopy = now
            }
        }
    }

    // MARK: Button over selection

    private func setSelectionButton(_ on: Bool) {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        button.hide()
        guard on else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDownPoint = NSEvent.mouseLocation
            self?.button.hide()
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            self?.mouseUp(event)
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            self?.button.hide()
        }) { mouseMonitors.append(m) }
    }

    private func mouseUp(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let dragged = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 6
        guard dragged || event.clickCount >= 2 else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let text = Selection.axSelectedText(), text.count < 8000 else { return }
            self?.button.show(at: point, text: text)
        }
    }
}

/// Small floating "translate" bubble shown next to freshly selected text.
final class SelectionButton {
    var onClick: ((String) -> Void)?
    private var panel: NSPanel?
    private var text = ""
    private var hideWork: DispatchWorkItem?

    func show(at point: NSPoint, text: String) {
        self.text = text
        let size = NSSize(width: 30, height: 30)
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        var origin = NSPoint(x: point.x + 10, y: point.y + 10)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let v = screen.visibleFrame
            origin.x = min(origin.x, v.maxX - size.width - 4)
            origin.y = min(origin.y, v.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: BubbleView { [weak self] in
            guard let self else { return }
            self.hide()
            self.onClick?(self.text)
        })
        return panel
    }
}

private struct BubbleView: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "translate")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1), Color(red: 0.55, green: 0.36, blue: 1)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
        .help("Translate with Parla")
    }
}

/// Right-click → Services → "Translate with Parla".
final class ServicesProvider: NSObject {
    var onText: ((String) -> Void)?

    @objc func translate(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard Settings.shared.servicesEnabled, let text = pboard.string(forType: .string) else { return }
        DispatchQueue.main.async { self.onText?(text) }
    }
}
