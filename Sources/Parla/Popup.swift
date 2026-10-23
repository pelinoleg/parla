import AppKit
import SwiftUI

/// Floating translation card next to the cursor. It takes keyboard focus without
/// activating Parla, so the app you were in stays frontmost and "Replace" can paste into it.
@MainActor
final class PopupController {
    private let model = PopupModel()
    private var panel: PopupPanel?
    private var outsideClick: Any?
    private var topLeft = NSPoint.zero
    var onSettings: (() -> Void)?

    func show(text: String?) {
        model.load(text)
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let width: CGFloat = 420
        var x = mouse.x + 12
        if x + width > visible.maxX - 8 { x = max(visible.minX + 8, mouse.x - width - 12) }
        var y = mouse.y - 12
        if y - 260 < visible.minY { y = min(visible.maxY - 8, mouse.y + 300) }
        topLeft = NSPoint(x: x, y: y)

        panel.setFrameTopLeftPoint(topLeft)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }

        outsideClick = outsideClick ?? NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        model.cancel()
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func makePanel() -> PopupPanel {
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                               backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }

        let root = PopupView(model: model, actions: .init(
            copy: { [weak self] text in Selection.copyToClipboard(text); self?.close() },
            replace: { [weak self] text in
                self?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Selection.paste(text) }
            },
            settings: { [weak self] in self?.close(); self?.onSettings?() },
            close: { [weak self] in self?.close() }
        ))
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host

        // Grow downwards from the anchored top-left corner as text streams in.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                panel.setFrameTopLeftPoint(self.topLeft)
            }
        }
        return panel
    }
}

final class PopupPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - View

struct PopupActions {
    let copy: (String) -> Void
    let replace: (String) -> Void
    let settings: () -> Void
    let close: () -> Void
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    let actions: PopupActions

    @State private var sourceExpanded = false
    @FocusState private var focus: Field?
    private enum Field { case input, intent }

    private let quick: [Language] = [.ro, .ru, .es, .ca, .en]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if model.source.isEmpty || model.phase == .idle {
                input
            } else {
                sourceBlock
                Divider().opacity(0.6)
                result
            }

            if model.replying { replyBlock }

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: model.replying)
        .onAppear { if model.source.isEmpty { focus = .input } }
    }

    // MARK: Header — source → target chips

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.detected?.code ?? "AUTO")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            ForEach(quick) { lang in chip(lang) }
            Menu {
                ForEach(Language.allCases.filter { !quick.contains($0) }) { lang in
                    Button(lang.nativeName) { model.setTarget(lang) }
                }
            } label: {
                Text(quick.contains(model.target) ? "···" : model.target.code)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Button(action: actions.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
    }

    private func chip(_ lang: Language) -> some View {
        let selected = model.target == lang
        return Button { model.setTarget(lang) } label: {
            Text(lang.code)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? Color.white : .primary.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06)))
                )
        }
        .buttonStyle(.plain)
        .help(lang.nativeName)
    }

    // MARK: Source

    private var input: some View {
        ZStack(alignment: .topLeading) {
            if model.source.isEmpty {
                Text("Type or paste text…  ⌘↩ to translate")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 19)
                    .padding(.vertical, 8)
            }
            TextEditor(text: $model.source)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .input)
                .frame(height: 110)
                .padding(.horizontal, 14)
                .onSubmit { model.translate() }
        }
        .background(
            Button("") { model.translate() }.keyboardShortcut(.return, modifiers: .command).hidden()
        )
    }

    private var sourceBlock: some View {
        Text(model.source)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(sourceExpanded ? nil : 3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { sourceExpanded.toggle() }
            .help("Double-click to expand")
    }

    // MARK: Result

    private var result: some View {
        ScrollingText(text: resultText, font: .systemFont(ofSize: 15), maxHeight: 320) {
            VStack(alignment: .leading, spacing: 8) {
                switch model.phase {
                case .failed(let message):
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message).font(.system(size: 12.5))
                            Button("Open Settings", action: actions.settings).controlSize(.small)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                default:
                    if model.output.isEmpty {
                        ShimmerLines()
                    } else {
                        Text(model.output + (model.phase == .working ? " ▍" : ""))
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var resultText: String {
        switch model.phase {
        case .failed(let message): return message + "\n\nOpen Settings"
        default: return model.output.isEmpty ? "\n\n" : model.output + " ▍"
        }
    }

    // MARK: Reply

    private var replyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("What to answer? Any language — I'll write it in \(model.replyLanguage.nativeName)",
                          text: $model.intent, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .focused($focus, equals: .intent)
                    .onSubmit { model.generateReply() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)

            if model.replyPhase != .idle {
                VStack(alignment: .leading, spacing: 6) {
                    switch model.replyPhase {
                    case .failed(let message):
                        Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                    default:
                        if model.reply.isEmpty {
                            ShimmerLines(count: 2)
                        } else {
                            Text(model.reply)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                            if !model.replyMeaning.isEmpty {
                                Text(model.replyMeaning)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 10)
            }
        }
        .onAppear { focus = .intent }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let p = model.provider {
                Text(p.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if model.replying, model.replyPhase == .done {
                FooterButton(title: "Copy reply", icon: "doc.on.doc") { actions.copy(model.reply) }
                FooterButton(title: "Paste", icon: "text.insert", prominent: true) { actions.replace(model.reply) }
            } else if model.phase == .done {
                FooterButton(title: "Reply", icon: "arrowshape.turn.up.left") { model.replying.toggle() }
                FooterButton(title: "Replace", icon: "text.insert", shortcut: "⌘↩") { actions.replace(model.output) }
                    .keyboardShortcut(.return, modifiers: .command)
                FooterButton(title: "Copy", icon: "doc.on.doc", shortcut: "↩", prominent: true) { actions.copy(model.output) }
                    .keyboardShortcut(model.replying ? nil : .defaultAction)
            }
        }
    }
}

private struct FooterButton: View {
    let title: String
    let icon: String
    var shortcut: String?
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
                if let shortcut {
                    Text(shortcut).font(.system(size: 10.5)).opacity(0.55)
                }
            }
            .foregroundStyle(prominent ? Color.white : .primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor.opacity(hover ? 0.9 : 1))
                                    : AnyShapeStyle(Color.primary.opacity(hover ? 0.1 : 0.06)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Text area that grows with its content up to `maxHeight`, then scrolls.
/// Height is measured with TextKit so the window can size itself before layout settles.
private struct ScrollingText<Content: View>: View {
    let text: String
    let font: NSFont
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: CGFloat(388), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: Self.paragraph]
        ).height
        ScrollView { content }
            .frame(height: min(max(measured, 34) + 26, maxHeight))
    }

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        return p
    }
}

/// Placeholder lines while the first words are on their way.
private struct ShimmerLines: View {
    var count = 3
    @State private var phase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(phase ? 0.12 : 0.05))
                    .frame(width: i == count - 1 ? 180 : 360, height: 11)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { phase = true } }
    }
}
