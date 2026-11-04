import Foundation
import SwiftUI
import os

struct Dictation: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var text: String
    var raw: String
    var app: String?
    var tone: String
    var seconds: Double
    /// File name inside clips/ when the audio was kept.
    var clip: String?
    /// What the user says the output should have been. Feeds the polish prompt as an example and `--eval`.
    var correction: String?
    var words: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    var hasClip: Bool { clip.map { FileManager.default.fileExists(atPath: Store.clipsDirectory.appendingPathComponent($0).path) } ?? false }
}

/// All-time counters, kept separately so trimming history doesn't lose them.
struct Stats: Codable {
    var words = 0
    var seconds = 0.0
    var dictations = 0
    var activeDays: [String] = []          // "yyyy-MM-dd"
    var perApp: [String: Int] = [:]
    var perTone: [String: Int] = [:]

    var wordsPerMinute: Int { seconds > 0 ? Int(Double(words) / (seconds / 60)) : 0 }

    /// Consecutive active days ending today or yesterday.
    var streak: Int {
        let days = Set(activeDays)
        var day = Date()
        if !days.contains(Stats.key(day)) { day = day.addingTimeInterval(-86_400) }
        var n = 0
        while days.contains(Stats.key(day)) { n += 1; day = day.addingTimeInterval(-86_400) }
        return n
    }

    static func key(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}

/// Single source of truth shared by the menu bar, the main window and the dictation pipeline.
@MainActor
final class Store: ObservableObject {
    @Published var config: Config
    @Published var history: [Dictation]
    @Published var stats: Stats
    @Published var status = "Loading…"
    /// Names from Contacts and today's calendar (when allowed), boosted in speech recognition.
    @Published var externalNames: [String] = []
    @Published var speechReady = false
    /// True when an OpenRouter key is configured; without one the app pastes rules-cleaned text.
    @Published var polishReady = false

    /// Set by AppDelegate; called after the speech version changes or any config field is saved.
    var onAsrChange: (() -> Void)?
    var onConfigChange: (() -> Void)?

    nonisolated static let historyURL = Config.directory.appendingPathComponent("history.json")
    static let statsURL = Config.directory.appendingPathComponent("stats.json")
    nonisolated static let clipsDirectory = Config.directory.appendingPathComponent("clips", isDirectory: true)
    let historyLimit = 200
    private let log = Logger(subsystem: "com.yaptype.app", category: "store")

    init() {
        do {
            config = try Config.load()
        } catch {
            // Keep the broken file for the user to fix rather than overwriting it on the next save.
            let backup = Config.fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Config.fileURL, to: backup)
            config = Config()
            log.error("Config unreadable (backed up to config.json.bak): \(error.localizedDescription, privacy: .public)")
        }
        let data = try? Data(contentsOf: Store.historyURL)
        if let data, let h = try? JSONDecoder().decode([Dictation].self, from: data) {
            history = h
        } else if let data, let old = try? JSONDecoder().decode([String].self, from: data) {
            // Migrate the plain-string history from earlier builds.
            history = old.map { Dictation(date: Date(), text: $0, raw: $0, app: nil, tone: "", seconds: 0) }
        } else {
            history = []
        }
        stats = (try? JSONDecoder().decode(Stats.self, from: Data(contentsOf: Store.statsURL))) ?? Stats()
    }

    func save() {
        do { try config.save() } catch { log.error("Config save failed: \(error.localizedDescription, privacy: .public)") }
        onConfigChange?()
    }

    /// Two-way binding into any config field that saves on every change.
    func bind<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: keyPath] },
                set: { self.config[keyPath: keyPath] = $0; self.save() })
    }

    func remember(_ d: Dictation) {
        history.insert(d, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        stats.words += d.words
        stats.seconds += d.seconds
        stats.dictations += 1
        let day = Stats.key(d.date)
        if !stats.activeDays.contains(day) { stats.activeDays.append(day) }
        stats.perApp[d.app ?? "unknown", default: 0] += 1
        stats.perTone[d.tone, default: 0] += 1
        persistHistory()
        try? JSONEncoder().encode(stats).write(to: Store.statsURL)
    }

    func delete(_ d: Dictation) {
        history.removeAll { $0.id == d.id }
        if let clip = d.clip { try? FileManager.default.removeItem(at: Store.clipsDirectory.appendingPathComponent(clip)) }
        persistHistory()
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: Store.historyURL)
        try? FileManager.default.removeItem(at: Store.clipsDirectory)
    }

    /// An empty or unchanged correction clears it.
    func setCorrection(_ d: Dictation, _ text: String) {
        guard let i = history.firstIndex(where: { $0.id == d.id }) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        history[i].correction = (t.isEmpty || t == d.text) ? nil : t
        persistHistory()
        // A corrected name becomes a dictionary entry with what was heard as its sound-alike.
        if !t.isEmpty, t != d.text {
            let signals = TextRules.learnSignals(heard: d.raw, corrected: t).filter { !config.learnedSignals.contains($0) }
            if !signals.isEmpty {
                config.learnedSignals = Array((config.learnedSignals + signals).suffix(20))
                save()
                log.info("Learned correction phrases: \(signals.joined(separator: ", "), privacy: .public)")
            }
            let learned = TextRules.learnNames(heard: d.raw, corrected: t)
            if !learned.isEmpty {
                config.dictionary = TextRules.mergeDictionary(config.dictionary, learned: learned)
                save()
                log.info("Learned from correction: \(learned.map { "\($0.term) <- \($0.alias)" }.joined(separator: ", "), privacy: .public)")
            }
        }
    }

    /// Latest corrections for a tone, oldest first, as (what was heard, what the user wanted).
    func corrections(tone: String, limit: Int = 5) -> [(String, String)] {
        history.filter { $0.tone == tone && $0.correction != nil }.prefix(limit).reversed().map { ($0.raw, $0.correction!) }
    }

    func allCorrections(limit: Int = 3) -> [String: [(String, String)]] {
        var out: [String: [(String, String)]] = [:]
        for name in config.tones.keys { let c = corrections(tone: name, limit: limit); if !c.isEmpty { out[name] = c } }
        return out
    }

    var correctionCount: Int { history.filter { $0.correction != nil }.count }

    private func persistHistory() {
        try? JSONEncoder().encode(history).write(to: Store.historyURL)
    }

    func setAsrVersion(_ v: String) {
        guard v != config.asrVersion else { return }
        config.asrVersion = v
        save()
        onAsrChange?()
    }
}
