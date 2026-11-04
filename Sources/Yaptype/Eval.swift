import Foundation

/// `Yaptype --eval` replays every corrected dictation that still has its audio clip through the current
/// engines, prompts and rules, and scores the result against the correction. Run it after any change to
/// see whether it helped on your own voice. Uses OpenRouter when a key is configured, otherwise the rules.
enum Eval {
    static func run() async -> Bool {
        let config: Config
        let history: [Dictation]
        do {
            config = try Config.load()
            // History from builds before the main window was a plain string list; it has nothing to replay.
            history = (try? JSONDecoder().decode([Dictation].self, from: Data(contentsOf: Store.historyURL))) ?? []
        } catch {
            print("eval: could not load config/history: \(error.localizedDescription)"); return false
        }
        let cases = history.filter { $0.correction != nil && $0.hasClip }.reversed()
        let noClip = history.filter { $0.correction != nil && !$0.hasClip }.count
        let noCorrection = history.filter { $0.correction == nil && $0.hasClip }.count
        print("eval: \(cases.count) corrected dictations with audio (\(noClip) corrections without a clip, \(noCorrection) clips not corrected yet)")
        guard !cases.isEmpty else {
            print("Turn on Settings > Keep audio clips, dictate, then use the pencil on a History row to save what you meant."); return false
        }

        let transcriber = Transcriber()
        let maybePolisher = Polisher(config: config)
        let polisher: Polisher? = maybePolisher.isConfigured ? maybePolisher : nil
        if polisher == nil { print("eval: no OpenRouter API key; scoring the deterministic rules only") }
        do {
            try await transcriber.load(version: config.asrVersion)
            if !CommandLine.arguments.contains("--no-boost") { await transcriber.setVocabulary(config.dictionary) }
        } catch {
            print("eval: speech model failed: \(error.localizedDescription)"); return false
        }

        func pad(_ s: String, _ w: Int) -> String { s.padding(toLength: w, withPad: " ", startingAt: 0) }
        func pct(_ x: Double) -> String { pad(String(Int((x * 100).rounded())) + "%", 8) }
        print("\n" + pad("#", 4) + pad("tone", 13) + pad("heard", 8) + pad("shipped", 8) + pad("now", 8) + "WER vs correction (lower is better; * = exact match)")
        var sumHeard = 0.0, sumShipped = 0.0, sumNow = 0.0, exact = 0
        var misses: [(Int, Dictation, String, String)] = []
        for (i, d) in cases.enumerated() {
            let want = d.correction!
            var raw = d.raw, now = "(failed)"
            do {
                let samples = try AudioRecorder.readWav(Store.clipsDirectory.appendingPathComponent(d.clip!))
                raw = try await transcriber.transcribe(samples)
                now = try await Pipeline.run(raw: raw, tone: d.tone, config: config, polisher: polisher, examples: [:])
            } catch {
                print("  #\(i + 1) failed: \(error.localizedDescription)")
            }
            let heard = TextRules.wordErrorRate(reference: want, hypothesis: raw)
            let shipped = TextRules.wordErrorRate(reference: want, hypothesis: d.text)
            let score = TextRules.wordErrorRate(reference: want, hypothesis: now)
            sumHeard += heard; sumShipped += shipped; sumNow += score
            let isExact = now == want
            if isExact { exact += 1 } else { misses.append((i + 1, d, raw, now)) }
            print(pad(String(i + 1), 4) + pad(d.tone, 13) + pct(heard) + pct(shipped) + pct(score) + (isExact ? "*" : ""))
        }
        let n = Double(cases.count)
        print(pad("avg", 17) + pct(sumHeard / n) + pct(sumShipped / n) + pct(sumNow / n) + "exact \(exact)/\(cases.count)")
        for (i, d, raw, now) in misses {
            print("\n#\(i) heard: \(raw)\n   now:   \(now)\n   want:  \(d.correction!)")
        }
        return true
    }
}
