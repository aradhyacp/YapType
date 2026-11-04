import FluidAudio
import Foundation
import os

/// Parakeet TDT (NVIDIA) running on CoreML via FluidAudio. Models download once from Hugging Face (~600 MB).
actor Transcriber {
    private var manager: AsrManager?
    var isReady: Bool { manager != nil }
    private var ctcModels: CtcModels?
    private var boosting: VocabularyBoostingSession?
    private var boostedTerms: [String] = []
    private let log = Logger(subsystem: "com.yaptype.app", category: "asr")

    func load(version: String) async throws {
        let v: AsrModelVersion = version == "v3" ? .v3 : .v2
        let models = try await AsrModels.downloadAndLoad(version: v)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
    }

    // MARK: Live dictation (text while talking)
    //
    // Parakeet decodes 15 s in ~150 ms here, so the simplest live scheme is also the most faithful: re-decode
    // everything said so far every few hundred ms. Past 14 s the oldest part is frozen at a quiet point (with
    // vocabulary rescoring, exactly like a batch result) and decoding continues from there.

    private var frozenText: [String] = []
    private var frozenSamples = 0
    // Re-decoding more than ~8 s of audio every few hundred ms made long dictations lag, so text is frozen
    // earlier: the quietest point between 5 s and 7.5 s is chosen once 8 s have accumulated.
    private static let freezeAfter = 8 * 16_000
    private static let freezeSearch = (5 * 16_000)...(7 * 16_000 + 8_000)

    func beginLive() { frozenText = []; frozenSamples = 0 }

    /// Best current guess for everything said so far (`samples` = all audio since the hotkey went down).
    func liveUpdate(_ samples: [Float]) async throws -> String {
        guard let manager else { return "" }
        if samples.count - frozenSamples > Self.freezeAfter {
            let cut = frozenSamples + Self.quietestPoint(in: samples, range: Self.freezeSearch, offset: frozenSamples)
            let text = try await transcribe(Array(samples[frozenSamples..<cut]))
            if !text.isEmpty { frozenText.append(text) }
            frozenSamples = cut
        }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let tail = try await manager.transcribe(Array(samples[frozenSamples...]), decoderState: &state).text
        return (frozenText + [tail.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Final transcript: frozen parts plus the rescored tail. Only the tail (≤ 14 s) is decoded after release.
    func liveFinish(_ samples: [Float]) async throws -> String {
        let tail = frozenSamples < samples.count ? try await transcribe(Array(samples[frozenSamples...])) : ""
        let text = (frozenText + [tail]).filter { !$0.isEmpty }.joined(separator: " ")
        beginLive()
        return text
    }

    /// Start of the quietest 200 ms inside `range` (relative to `offset`), so freezes land between words.
    private static func quietestPoint(in samples: [Float], range: ClosedRange<Int>, offset: Int) -> Int {
        let win = 3200
        var best = range.lowerBound, bestEnergy = Float.greatestFiniteMagnitude
        var i = range.lowerBound
        while i + win <= range.upperBound, offset + i + win <= samples.count {
            var e: Float = 0
            for j in (offset + i)..<(offset + i + win) { e += samples[j] * samples[j] }
            if e < bestEnergy { bestEnergy = e; best = i }
            i += 800
        }
        return best
    }

    /// Biases recognition itself toward the dictionary: a small CTC model (parakeet-ctc-110m, downloaded once)
    /// spots the terms in the audio and the transcript is rescored to use them. No-op when the list is unchanged.
    /// `terms` are dictionary lines; `extra` are names from the field being typed in, Contacts and Calendar.
    /// Only the terms themselves go to the booster (sound-alikes are for the exact-match rule), and the similarity
    /// bar is high: with the default it rewrote "kind regards" as "Zentro regards".
    func setVocabulary(_ terms: [String], extra: [String] = []) async {
        var names = TextRules.dictionaryTerms(terms)
        for n in extra where !names.contains(where: { $0.lowercased() == n.lowercased() }) { names.append(n) }
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }
        guard cleaned != boostedTerms else { return }
        boostedTerms = cleaned
        boosting = nil
        guard !cleaned.isEmpty else { return }
        do {
            if ctcModels == nil { ctcModels = try await CtcModels.downloadAndLoad() }
            let context = CustomVocabularyContext(terms: cleaned.map { CustomVocabularyTerm(text: $0) }, minSimilarity: 0.75, minTermLength: 4)
            // The acoustic "rescue" pass over-fires on small dictionaries (it turned "hey so" into "Yaptype");
            // FluidAudio recommends it off for short keyword lists. String-similarity boosting still runs.
            boosting = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels!,
                                                           config: .init(spotterRescueEnabled: false))
            log.info("Vocabulary boosting on for \(cleaned.count) terms")
        } catch {
            log.error("Vocabulary boosting unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw NSError(domain: "Yaptype", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech model still loading"]) }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        var text = result.text
        if let boosting, let timings = result.tokenTimings,
           let out = await boosting.rescore(text: text, tokenTimings: timings, audioSamples: samples), out.wasModified {
            log.info("Vocabulary: \(text, privacy: .public) -> \(out.text, privacy: .public)")
            text = out.text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
