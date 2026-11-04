import Foundation

/// `Yaptype --polishtest "raw transcript"`: runs the polish step exactly as the app does (tones, dictionary, memory,
/// corrections, no field context) and prints where the time went. Uses OpenRouter.
enum PolishTest {
    static func run(_ raw: String) async -> Bool {
        guard var config = try? Config.load() else { return false }
        // YAPTYPE_TONES_JSON = {"name": "instruction"} tries tone definitions without saving them.
        if let raw = ProcessInfo.processInfo.environment["YAPTYPE_TONES_JSON"], let data = raw.data(using: .utf8),
           let extra = try? JSONDecoder().decode([String: String].self, from: data) {
            for (k, v) in extra { config.tones[k] = v }
        }
        let toneNames = ProcessInfo.processInfo.environment["YAPTYPE_TONES"]?.split(separator: ",").map(String.init) ?? ["casual", "professional"]
        let history = (try? JSONDecoder().decode([Dictation].self, from: Data(contentsOf: Store.historyURL))) ?? []
        let polisher = Polisher(config: config)
        guard polisher.isConfigured else {
            print("polishtest: no OpenRouter API key (add openRouterAPIKey to config.json or Settings)")
            return false
        }
        var examples: [String: [(String, String)]] = [:]
        for name in config.tones.keys {
            let c = history.filter { $0.tone == name && $0.correction != nil }.prefix(3).reversed().map { ($0.raw, $0.correction!) }
            if !c.isEmpty { examples[name] = c }
        }
        for tone in toneNames {
            let t0 = Date()
            let out = (try? await Pipeline.run(raw: raw, tone: tone, config: config, polisher: polisher, examples: examples)) ?? "(failed)"
            print("\(tone): \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            print("  -> \(out)")
        }
        return true
    }
}
