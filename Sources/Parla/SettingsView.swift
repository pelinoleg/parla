import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @State private var trusted = Selection.isTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !trusted {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Allow Accessibility access").font(.headline)
                            Text("Parla needs it to read the text you select in other apps, notice double ⌘C and paste translations back. Nothing leaves your Mac except the text you translate.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Allow…") { Selection.requestTrust() }
                                    .buttonStyle(.borderedProminent)
                                Button("Open System Settings") { Selection.openAccessibilitySettings() }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Languages") {
                Picker("Translate into", selection: $settings.target) { languageOptions }
                Picker("If the text is already in it, into", selection: $settings.alternate) { languageOptions }
                Picker("My language", selection: $settings.myLanguage) { languageOptions }
                    .help("Replies you write are shown back in this language so you can check them")
            }

            Section("How to translate") {
                HStack {
                    Toggle("Shortcut", isOn: $settings.hotkeyEnabled)
                    Spacer()
                    ShortcutRecorder(shortcut: $settings.shortcut)
                        .disabled(!settings.hotkeyEnabled)
                }
                Toggle("Press ⌘C twice quickly", isOn: $settings.doubleCopyEnabled)
                Toggle("Show a button next to selected text", isOn: $settings.selectionButtonEnabled)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Right-click → Services → Translate with Parla", isOn: $settings.servicesEnabled)
                    Text("To hide it from the menu completely: System Settings → Keyboard → Keyboard Shortcuts → Services.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(Array(settings.providerOrder.enumerated()), id: \.element) { index, provider in
                    ProviderRow(provider: provider, index: index, count: settings.providerOrder.count)
                }
            } header: {
                Text("Translators")
            } footer: {
                Text("Tried top to bottom: if one has no key or fails, the next one takes over. Keys are stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onReceive(timer) { _ in trusted = Selection.isTrusted }
    }

    @ViewBuilder private var languageOptions: some View {
        ForEach(Language.allCases) { Text($0.nativeName).tag($0) }
    }
}

private struct ProviderRow: View {
    let provider: ProviderID
    let index: Int
    let count: Int
    @ObservedObject private var settings = Settings.shared
    @State private var key = ""
    @State private var model = ""
    @State private var test: String?
    @State private var testing = false

    private var enabled: Binding<Bool> {
        Binding(get: { !settings.disabledProviders.contains(provider) },
                set: { on in
                    if on { settings.disabledProviders.remove(provider) } else { settings.disabledProviders.insert(provider) }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                status
                Spacer()
                HStack(spacing: 2) {
                    Button { move(-1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 18) }
                        .disabled(index == 0)
                    Button { move(1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 18) }
                        .disabled(index == count - 1)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .help("Change order")
                Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }

            if provider.needsKey {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        fieldLabel("Key")
                        SecureField("API key", text: $key, prompt: Text(provider.keyPrefix))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveKey)
                        if let url = provider.keyURL {
                            Link("Get key", destination: url)
                                .font(.system(size: 11))
                        }
                    }
                    GridRow {
                        fieldLabel("Model")
                        TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { settings.models[provider.rawValue] = model }
                        testButton
                    }
                }
                .padding(.leading, 30)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Text("On-device and free, works offline. No Catalan; languages may need downloading in System Settings → General → Language & Region → Translation Languages.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    testButton
                }
                .padding(.leading, 30)
            }

            if let test {
                Text(test)
                    .font(.system(size: 11))
                    .foregroundStyle(test.hasPrefix("✓") ? .green : .orange)
                    .textSelection(.enabled)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 6)
        .opacity(enabled.wrappedValue ? 1 : 0.5)
        .onAppear {
            key = Keychain.get(provider.rawValue) ?? ""
            model = settings.models[provider.rawValue] ?? ""
        }
        .onDisappear { saveKey(); settings.models[provider.rawValue] = model }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .leading)
    }

    private var testButton: some View {
        Button(action: runTest) {
            Text(testing ? "Testing…" : "Test").frame(minWidth: 52)
        }
        .controlSize(.small)
        .disabled(testing)
    }

    @ViewBuilder private var status: some View {
        let ready = !provider.needsKey || !key.isEmpty || Keychain.get(provider.rawValue) != nil
        Text(ready ? "ready" : "no key")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ready ? Color.green : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((ready ? Color.green : Color.primary).opacity(0.1)))
    }

    private func saveKey() { Keychain.set(key, for: provider.rawValue) }

    private func move(_ delta: Int) {
        var order = settings.providerOrder
        let j = index + delta
        guard order.indices.contains(j) else { return }
        order.swapAt(index, j)
        withAnimation { settings.providerOrder = order }
    }

    private func runTest() {
        saveKey()
        settings.models[provider.rawValue] = model
        testing = true
        test = nil
        Task { @MainActor in
            var out = ""
            do {
                for try await chunk in Translator.engine(for: provider).stream(
                    system: Prompts.translate(source: .es, target: settings.target),
                    user: "Bon dia! Demà no hi ha escola.", source: .ca, target: settings.target) {
                    out += chunk
                }
                test = "✓ " + out.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                test = error.localizedDescription
            }
            testing = false
        }
    }
}

/// Click, then press the new key combination.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : shortcut.display)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 90)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let mods = Shortcut.carbonModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            // Require ⌘, ⌃ or ⌥ so the shortcut doesn't swallow normal typing.
            guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { NSSound.beep(); return nil }
            shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
