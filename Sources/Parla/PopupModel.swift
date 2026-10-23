import Foundation
import SwiftUI

@MainActor
final class PopupModel: ObservableObject {
    enum Phase: Equatable { case idle, working, done, failed(String) }

    @Published var source = ""
    @Published var detected: Language?
    @Published var target: Language = Settings.shared.target
    @Published var output = ""
    @Published var provider: ProviderID?
    @Published var phase: Phase = .idle

    // Reply mode
    @Published var replying = false
    @Published var intent = ""
    @Published var reply = ""
    @Published var replyMeaning = ""
    @Published var replyPhase: Phase = .idle

    private var task: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?

    var replyLanguage: Language { detected ?? .es }

    func load(_ text: String?) {
        cancel()
        source = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        output = ""; provider = nil; phase = .idle
        replying = false; intent = ""; reply = ""; replyMeaning = ""; replyPhase = .idle
        detected = source.isEmpty ? nil : Detector.detect(source)
        let s = Settings.shared
        // Already in the target language → translate the other way.
        target = detected == s.target ? s.alternate : s.target
        if !source.isEmpty { translate() }
    }

    func setTarget(_ language: Language) {
        guard language != target || phase != .done else { return }
        target = language
        if !source.isEmpty { translate() }
    }

    func translate() {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if detected == nil { detected = Detector.detect(text) }
        task?.cancel()
        output = ""; provider = nil; phase = .working
        let system = Prompts.translate(source: detected, target: target)
        let source = detected, target = target
        task = Task {
            do {
                for try await chunk in Translator.run(system: system, user: text, source: source, target: target) {
                    if provider != chunk.provider { output = ""; provider = chunk.provider }
                    output += chunk.text
                }
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                phase = .done
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func generateReply() {
        let intent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { return }
        replyTask?.cancel()
        reply = ""; replyMeaning = ""; replyPhase = .working
        let lang = replyLanguage
        let mine = Settings.shared.myLanguage
        let system = Prompts.reply(to: lang)
        let user = Prompts.replyInput(original: source, intent: intent)
        replyTask = Task {
            do {
                var started = false
                for try await chunk in Translator.run(system: system, user: user, source: nil, target: lang) {
                    if !started { reply = ""; started = true }
                    reply += chunk.text
                }
                reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                replyPhase = .done
                // Back-translation so you can check what you're about to send.
                guard lang != mine else { return }
                for try await chunk in Translator.run(system: Prompts.translate(source: lang, target: mine),
                                                      user: reply, source: lang, target: mine) {
                    replyMeaning += chunk.text
                }
            } catch {
                if !Task.isCancelled, reply.isEmpty { replyPhase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        replyTask?.cancel(); replyTask = nil
    }
}
