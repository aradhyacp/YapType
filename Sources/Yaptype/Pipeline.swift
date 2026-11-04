import Foundation
import os

/// Everything between the raw transcript and the text that gets pasted. Shared by the app and `--eval`
/// so a replay scores exactly what a real dictation would have produced.
enum Pipeline {
    private static let log = Logger(subsystem: "com.yaptype.app", category: "pipeline")
    private static let signals = try! NSRegularExpression(pattern: #"(?i)\b(sorry|actually|no[,\s]+wait|wait[,\s]+no|oh[,\s]+no|i mean|scratch that|forget that|never ?mind|correction|number (one|two|1|2)|first(ly)?|second(ly)?)\b"#)

    private static let corrections = try! NSRegularExpression(pattern: #"(?i)\b(sorry|no[,\s]+wait|wait[,\s]+no|oh[,\s]+no|i mean|scratch that|forget that|never ?mind|correction|actually|let me rephrase)\b"#)
    /// A one or two word aside set off by commas ("..., I know, ...", "..., no wake, ...") is often a misheard
    /// correction; it counts as a signal so the model gets to decide.
    private static let aside = try! NSRegularExpression(pattern: #",\s*[A-Za-z']+(?:\s+[A-Za-z']+)?\s*,"#)
    static func hasCorrectionSignal(_ text: String, learned: [String] = []) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        if corrections.firstMatch(in: text, range: r) != nil || aside.firstMatch(in: text, range: r) != nil { return true }
        let lower = " " + text.lowercased() + " "
        return learned.contains { lower.contains(" " + $0 + " ") || lower.contains(" " + $0 + ",") }
    }

    static func run(raw: String, tone: String, config: Config, polisher: Polisher?,
                    examples: [String: [(String, String)]], context: FieldContext? = nil) async throws -> String {
        // Spoken commands ("new line", "sam at example dot com") apply in every tone, verbatim included.
        let text = TextRules.applyDictionary(TextRules.applyCommands(raw), config.dictionary)
        guard let instruction = config.tones[tone], !instruction.isEmpty, let polisher else { return text }
        let pre = TextRules.stripFillers(text)
        // Fast path: a short casual message with nothing to reason about needs no model. Casual means lowercase and
        // no punctuation apart from ? and apostrophes, which the rules can do in 0 ms.
        // Only tiny messages ("ok see you at 8") skip the model; anything that could hold a correction reaches it.
        if tone == "casual" || tone == "supercasual", pre.split(separator: " ").count <= 4, !pre.contains("\n"),
           signals.firstMatch(in: pre, range: NSRange(pre.startIndex..., in: pre)) == nil, !hasCorrectionSignal(text, learned: config.learnedSignals) {
            return finalize(TextRules.casual(pre, keeping: TextRules.dictionaryTerms(config.dictionary), superCasual: tone == "supercasual"))
        }
        do {
            let polished = try await polisher.polish(pre, tone: tone, tones: config.tones, dictionary: config.dictionary,
                                                     memory: config.memory, examples: examples, context: context)
            if TextRules.looksUnfaithful(input: pre, output: polished, allowed: TextRules.dictionaryTerms(config.dictionary)) {
                log.error("Guardrail: model output rejected, pasting cleaned transcript instead. Output was: \(polished, privacy: .public)")
                return fallback(pre, context: context)
            }
            var out = TextRules.applyDictionary(polished, config.dictionary)
            if let before = context?.before, !before.isEmpty { out = TextRules.stripEcho(out, before: before) }
            return finalize(out)
        } catch {
            // OpenRouter being down or rate-limited must never lose a dictation: paste the deterministic rules output.
            log.error("Polishing failed, using rules-only text: \(error.localizedDescription, privacy: .public)")
            return fallback(pre, context: context)
        }
    }

    private static func finalize(_ text: String) -> String {
        TextRules.questionMarks(TextRules.applyCountedLists(TextRules.applyLists(TextRules.layoutMessage(TextRules.layoutGreeting(text)))))
    }

    private static func fallback(_ text: String, context: FieldContext?) -> String {
        var out = text
        if let before = context?.before, !before.isEmpty { out = TextRules.stripEcho(out, before: before) }
        return finalize(out)
    }
}
