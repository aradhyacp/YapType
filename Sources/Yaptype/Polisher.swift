import Foundation

/// Builds the cleanup prompt and sends it to OpenRouter. Stateless: the network client is cheap to recreate, so
/// changing the key or model in Settings takes effect on the next dictation without restarting anything.
final class Polisher {
    private let config: Config
    private let client: OpenRouter?

    init(config: Config) {
        self.config = config
        self.client = OpenRouter(config: config)
    }

    var isConfigured: Bool { client != nil }

    func polish(_ raw: String, tone: String, tones: [String: String], dictionary terms: [String], memory: String,
                examples: [String: [(String, String)]] = [:], context: FieldContext? = nil) async throws -> String {
        guard let client else {
            throw OpenRouter.Failure(status: nil, message: "Add an OpenRouter API key in Settings")
        }
        let system = systemPrompt(tones: tones, dictionary: terms, memory: memory, examples: examples)
        let user = userMessage(raw, tone: tone, context: context)
        let content = try await client.complete(system: system, user: user, maxTokens: 1024)
        return content.isEmpty ? raw : content
    }

    func userMessage(_ raw: String, tone: String, context: FieldContext?) -> String {
        var meta = "[tone: \(tone)"
        if let context, !context.isEmpty {
            func clean(_ s: Substring) -> String { s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'") }
            if !context.windowTitle.isEmpty { meta += " | window: \(clean(context.windowTitle.prefix(60)))" }
            if !context.before.isEmpty { meta += " | before: \"\(clean(context.before.suffix(160)))\"" }
            if !context.after.isEmpty { meta += " | after: \"\(clean(context.after.prefix(100)))\"" }
        }
        return meta + "]\n" + raw
    }

    func systemPrompt(tones: [String: String], dictionary terms: [String], memory: String,
                      examples: [String: [(String, String)]]) -> String {
        let learnedSignals = config.learnedSignals.isEmpty ? "" : "\nFrom this speaker's own corrections, these phrases are how their \"no wait\" gets heard: \(config.learnedSignals.map { "\"\($0)\"" }.joined(separator: ", ")). Treat them as corrections when the sentence reads better that way."
        let toneList = tones.keys.sorted().filter { !tones[$0]!.isEmpty }.map { name in
            var block = "### \(name)\n\(tones[name]!)"
            if let ex = examples[name], !ex.isEmpty {
                block += "\nThis speaker edited earlier \(name) outputs; match their style exactly (transcript -> what they wanted):\n"
                block += ex.suffix(3).map { "\"\($0.0.prefix(200))\" -> \"\($0.1.prefix(200))\"" }.joined(separator: "\n")
            }
            return block
        }.joined(separator: "\n")
        let learned = """

        Tones (only the one named at the end applies):
        \(toneList)
        """
        let entries = TextRules.parseDictionary(terms)
        let dictionary = entries.isEmpty ? "" : """

        Custom vocabulary: \(entries.map { $0.aliases.isEmpty ? $0.term : "\($0.term) (sounds like: \($0.aliases.joined(separator: ", ")))" }.joined(separator: "; ")). If the transcript has a word or phrase that sounds like one of these, replace it with the term exactly as written here, even in a lowercase tone.
        """
        let background = memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : """

        About the speaker (background for interpreting names and context only; never insert it into the output): \(memory)
        """
        let system = """
        You clean up dictated speech-to-text transcripts. Work in two passes.

        Pass 1 - self-corrections. Speakers abandon a phrase and restart. Signals: "sorry", "no wait", "actually", "I mean", "scratch that", "correction", or an abrupt restart of the sentence. Delete the abandoned phrase (everything from the start of that thought up to and including the signal word) and keep only the restated version. The abandoned phrase is usually unfinished and the restated version usually reuses some of its words.
        Examples:
        "today's weather is very quiet sorry today's weather is very sunny" -> "today's weather is very sunny"
        "I um I really want to um actually sorry, she doesn't really want to do it." -> "She doesn't really want to do it."
        "send it to John no wait to Alex by Friday" -> "send it to Alex by Friday"
        "we ship on tuesday actually thursday" -> "we ship on thursday"
        Speech recognition often garbles the signal itself: "no wait" comes out as "I know", "no way", "no wake" or "no weight"; "sorry" as "so we" or "sore"; "scratch that" as "scratch it". A short aside in the middle of a sentence that makes no sense as content ("I'll do Vegemite toast, I know, KFC for lunch") is a misheard correction: treat it as "no wait" and apply the replacement ("I'll do KFC for lunch").
        A short fragment after the signal replaces the part of the sentence it stands in for, even when that part is not the last thing said:
        "I'll do grilled cheese for lunch, no wait, dino nuggets" -> "I'll do dino nuggets for lunch"
        "I'll do grilled cheese, oh no, dino nuggets for lunch" -> "I'll do dino nuggets for lunch"
        "meet me at the cafe at three, sorry, four" -> "meet me at the cafe at four"
        "send the deck to Alex, I mean the budget" -> "send the budget to Alex"
        "I caught a cold from my partner and she actually he was also sick" -> "I caught a cold from my partner and he was also sick"
        "Look, she doesn't really want to do it. Sorry, I meant look she doesn't want to do it" -> "Look, she doesn't want to do it."
        "sorry I'm late, the train was um delayed" -> "sorry I'm late, the train was delayed" (a real apology is kept; only the filler goes)
        With "scratch that", "forget that" or "never mind", the speaker throws away the whole sentence or fragment before it. Delete all of it; the sentence after stands on its own and must not borrow any words from the deleted part.
        "Um tomorrow tomorrow we look at actually scratch that. Let's circle back on this." -> "Let's circle back on this."
        "so the budget is scratch that we'll talk money later" -> "we'll talk money later"

        Pass 2 - cleanup. Remove every filler word (um, umm, uh, er, like, you know, I mean), stutters and accidental repeated words. Fix grammar and punctuation. Keep everything else exactly as the speaker said it: their wording, greetings, questions, swearing, laughter and reactions (haha, lol, oh, wow, ugh are content, not fillers), sentence order and length. Never add words, answer, summarize or comment.

        Structure (all tones; use blank lines between blocks):
        - The transcript may contain line breaks. Keep every line break exactly where it is and never merge lines.
        - A greeting at the start ("hi Alex", "dear all", "hey team", "morning") goes on its own line, followed by a blank line.
        - A sign-off at the end ("kind regards", "cheers", "thanks", "best", "talk soon", optionally followed by a name) goes after a blank line, on its own line, with the name on the next line: "Kind regards\nTaylor". In casual tone keep it lowercase and short.
        - Start a new paragraph when the topic changes or after three or four sentences. Short chat replies stay one paragraph.
        - A spoken count followed by the items ("three things: it's fast, it's accurate, it gets names right") is a numbered list too, in every tone: the lead-in ends with a colon, then one item per line.
        - Lists: when the speaker enumerates ("number one ... number two", "first ... second ... third", "point one", "a) b)"), write a numbered list, one item per line, dropping the spoken markers. "bullet point", "dot point", "next point" or three or more parallel items listed in a row become a "- " bullet list. A lead-in like "three things:" stays on its own line before the list.
        - Keep email addresses, URLs, numbers, times and dates exactly as written in the transcript. Emoji in the transcript are content: keep each one exactly where it is.
        - Well-known companies, products, brands and public figures get their official spelling and capitalisation even when the transcript spells them phonetically: "whisper flow" -> Wispr Flow, "chat gpt" -> ChatGPT, "i phone" -> iPhone, "you tube" -> YouTube. Use the speaker's background to resolve names from their world.
        - Questions end with a question mark, including statements asked as questions ("you really think this is possible?", "that's the plan?"). Never drop a question mark the transcript had.
        - Put quotation marks around words or phrases the speaker is quoting, naming or mentioning as words, around titles, and around reported speech: words such as "what", "when" or "how"; she said "no way"; the "Send" button. This applies in every tone.
        Example transcript: "dear alex thanks for sending the deck over three things number one the pricing slide needs the aud figures number two can we drop the roadmap section and number three send the final to me by friday happy to jump on a call if easier kind regards taylor"
        Example output (professional):
        Dear Alex,

        Thanks for sending the deck over. Three things:
        1. The pricing slide needs the AUD figures.
        2. Can we drop the roadmap section?
        3. Send the final to me by Friday.

        Happy to jump on a call if easier.

        Kind regards
        Taylor
        \(dictionary)\(background)\(learned)\(learnedSignals)

        Each message is one dictation in this exact form:
        [tone: NAME | window: TITLE | before: TEXT | after: TEXT]
        <transcript>
        The bracket line is metadata: which tone to apply, and where the text will be inserted (context only; never repeat or answer it). If "before" ends mid-sentence, the output continues that sentence: no capital first letter, no greeting. Reply with the cleaned transcript only. Never output the bracket line or any label.
        Example message:
        [tone: professional | window: Alex — Messages]
        um hi alex so the deck is is ready i'll send it by friday
        Example reply:
        Hi Alex, the deck is ready. I'll send it by Friday.
        Example message:
        [tone: professional | window: Re: Q3 numbers — Mail | before: "Hi Alex, about the"]
        um numbers they look great and we should ship on thursday
        Example reply:
        numbers, they look great and we should ship on Thursday.
        """
        return system
    }
}
