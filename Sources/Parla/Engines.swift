import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A single LLM / translation backend. Yields text chunks as they arrive.
protocol Engine {
    func stream(system: String, user: String, source: Language?, target: Language) -> AsyncThrowingStream<String, Error>
}

// MARK: - Claude (raw HTTP, no Swift SDK exists)

struct ClaudeEngine: Engine {
    let key: String
    let model: String

    func stream(system: String, user: String, source: Language?, target: Language) -> AsyncThrowingStream<String, Error> {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Translation is easy work: keep thinking short so text starts flowing quickly.
        if !model.contains("haiku-4") && !model.contains("3-") {
            body["output_config"] = ["effort": "low"]
        }
        // Server-side fallback if a safety classifier declines (supported on these models only).
        if ["opus-5", "fable-5", "sonnet-5-5"].contains(where: model.contains) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return SSE.stream(request) { event in
            switch event["type"] as? String {
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            case "message_delta":
                if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                    throw EngineError(message: "Claude declined this text")
                }
                return nil
            case "error":
                let err = event["error"] as? [String: Any]
                throw EngineError(message: "Claude: \(err?["message"] as? String ?? "error")")
            default:
                return nil
            }
        }
    }
}

// MARK: - OpenAI and DeepSeek (same chat-completions protocol)

struct OpenAICompatibleEngine: Engine {
    let name: String
    let baseURL: String
    let key: String
    let model: String

    func stream(system: String, user: String, source: Language?, target: Language) -> AsyncThrowingStream<String, Error> {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        // Reasoning models: keep reasoning short, translation doesn't need it.
        if model.hasPrefix("gpt-5") || model.hasPrefix("o") {
            body["reasoning_effort"] = "low"
        }
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return SSE.stream(request) { event in
            if let err = event["error"] as? [String: Any] {
                throw EngineError(message: "\(name): \(err["message"] as? String ?? "error")")
            }
            let choice = (event["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        }
    }
}

// MARK: - Apple on-device translation (macOS 26+, last resort)

struct AppleEngine: Engine {
    func stream(system: String, user: String, source: Language?, target: Language) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    #if canImport(Translation) && compiler(>=6.2)
                    if #available(macOS 26.0, *), let source {
                        let session = TranslationSession(installedSource: source.localeLanguage, target: target.localeLanguage)
                        let response: TranslationSession.Response
                        do {
                            response = try await session.translate(user)
                        } catch {
                            throw EngineError(message: "Apple: \(source.nativeName) → \(target.nativeName) isn't downloaded — System Settings → General → Language & Region → Translation Languages")
                        }
                        continuation.yield(response.targetText)
                        continuation.finish()
                        return
                    }
                    #endif
                    throw EngineError(message: "Apple translation is unavailable for this language pair")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Server-sent events

enum SSE {
    /// Streams a POST request, parsing `data:` lines as JSON and mapping each to an optional text chunk.
    static func stream(_ request: URLRequest,
                       map: @escaping ([String: Any]) throws -> String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var raw = ""
                        for try await line in bytes.lines { raw += line; if raw.count > 2000 { break } }
                        throw EngineError(message: Self.describe(status: status, body: raw))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let text = try map(json), !text.isEmpty { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func describe(status: Int, body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            return "HTTP \(status): \(msg)"
        }
        switch status {
        case 401, 403: return "HTTP \(status): invalid API key"
        case 429: return "HTTP 429: rate limit or no credit"
        default: return "HTTP \(status)"
        }
    }
}

// MARK: - Language detection

enum Detector {
    static func detect(_ text: String) -> Language? {
        let r = NLLanguageRecognizer()
        let map: [NLLanguage: Language] = [
            .romanian: .ro, .russian: .ru, .spanish: .es, .catalan: .ca, .english: .en,
            .ukrainian: .uk, .french: .fr, .german: .de, .italian: .it, .portuguese: .pt,
        ]
        r.languageConstraints = Array(map.keys)
        r.processString(text)
        guard let best = r.dominantLanguage else { return nil }
        return map[best]
    }
}
