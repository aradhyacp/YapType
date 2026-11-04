import Foundation
import os

/// Text-only polishing through OpenRouter's chat-completions API. The microphone audio never leaves this Mac:
/// Parakeet transcribes locally, then only the transcript (plus dictionary/tone context) is sent here.
struct OpenRouter {
    struct Failure: LocalizedError {
        let status: Int?
        let message: String
        var errorDescription: String? { "OpenRouter\(status.map { " \($0)" } ?? ""): \(message)" }
        /// Auth errors will fail on every model, so they are not worth a fallback attempt.
        var shouldTryFallback: Bool { status != 401 && status != 403 }
    }

    let apiKey: String
    let models: [String]
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let log = Logger(subsystem: "com.yaptype.app", category: "openrouter")

    /// nil when no key is configured, which makes the app skip the network and paste rules-cleaned text.
    init?(config: Config) {
        let key = config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        apiKey = key
        var seen = Set<String>()
        models = [config.openRouterModel, config.openRouterFallbackModel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Tries the primary model, then the fallback on rate limits, outages or model errors.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var lastError: Error?
        for (index, model) in models.enumerated() {
            do {
                return try await complete(model: model, system: system, user: user, maxTokens: maxTokens)
            } catch {
                lastError = error
                let hasFallback = index < models.count - 1
                let retry = (error as? Failure)?.shouldTryFallback ?? true
                guard hasFallback, retry else { throw error }
                Self.log.notice("OpenRouter model \(model, privacy: .public) failed; trying the fallback: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw lastError ?? Failure(status: nil, message: "No polishing model configured")
    }

    private func complete(model: String, system: String, user: String, maxTokens: Int) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        // Nemotron enables high reasoning by default, which would add seconds and tokens to a cleanup task.
        // Gemma does not enable reasoning by default and ignores this field.
        if model.contains("nemotron") { body["reasoning"] = ["effort": "none"] }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Yaptype/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("Yaptype", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard let status, (200..<300).contains(status) else {
            throw Failure(status: status, message: Self.errorMessage(from: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(status: status, message: "The response was not JSON")
        }
        if let error = json["error"] as? [String: Any] {
            throw Failure(status: status, message: (error["message"] as? String) ?? "\(error)")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var content = message["content"] as? String else {
            throw Failure(status: status, message: "The response had no message content")
        }
        if let r = content.range(of: "</think>") { content = String(content[r.upperBound...]) }
        let visible = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Self.log.info("OpenRouter \(model, privacy: .public) in \(ms, privacy: .public) ms")
        return visible
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "empty response" : String(text.prefix(300))
    }
}
