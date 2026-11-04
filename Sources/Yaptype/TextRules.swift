import Foundation

/// Deterministic text rules that run around the polish model: cheap cleanup before it, a sanity check after it.
enum TextRules {
    // MARK: Spoken commands (applied in every tone, including verbatim)

    private static let commands: [(NSRegularExpression, String)] = [
        (rx(#"[,.]?\s*\b(new paragraph|paragraph break)\b[,.]?\s*"#), "\n\n"),
        (rx(#"[,.]?\s*\b(new line|newline|line break)\b[,.]?\s*"#), "\n"),
        (rx(#"[,.]?\s*\b(bullet point|dot point|new bullet|next bullet)\b[,.]?\s*"#), "\n- "),
        (rx(#"\s*\b(full stop|fullstop)\b[,.]?"#), "."),
        (rx(#"\s*\bquestion mark\b[,.]?"#), "?"),
        (rx(#"\s*\bexclamation (mark|point)\b[,.]?"#), "!"),
        // "sam at example dot com" -> sam@example.com ; "acme hub dot com dot au" -> acmehub.com.au
        (rx(#"\b([\w.-]+) at ([\w-]+)((?: dot [a-z]{2,4})+)\b"#), "$1@$2$3"),
        (rx(#"\b([\w-]+)((?: dot [a-z]{2,4})+)\b"#), "$1$2"),
    ]
    private static let dot = rx(#" dot ([a-z]{2,4})\b"#)

    /// Spoken emoji: "laugh cry emoji", "a thumbs up emoji", "fire emoji". Longest names first so "crying laugh"
    /// beats "crying".
    static let emojiNames: [(String, String)] = [
        ("laugh cry", "😂"), ("laughing cry", "😂"), ("laugh crying", "😂"), ("laughing crying", "😂"), ("cry laugh", "😂"),
        ("crying laugh", "😂"), ("crying laughing", "😂"), ("cry laughing", "😂"), ("tears of joy", "😂"), ("laughing", "😂"), ("laugh", "😂"),
        ("rolling on the floor", "🤣"), ("rofl", "🤣"), ("happy cry", "🥲"), ("smiling cry", "🥲"),
        ("sobbing", "😭"), ("loud crying", "😭"), ("bawling", "😭"), ("crying", "😢"), ("cry", "😢"), ("sad", "😢"),
        ("heart eyes", "😍"), ("blowing kiss", "😘"), ("kiss", "😘"), ("sweat smile", "😅"), ("nervous laugh", "😅"),
        ("grinning", "😁"), ("grin", "😁"), ("smiley", "😊"), ("smiling", "😊"), ("smile", "😊"), ("slight smile", "🙂"),
        ("winking", "😉"), ("wink", "😉"), ("sunglasses", "😎"), ("cool", "😎"), ("thinking", "🤔"), ("grimace", "😬"), ("grimacing", "😬"),
        ("eye roll", "🙄"), ("rolling eyes", "🙄"), ("shrug", "🤷"), ("shrugging", "🤷"), ("skull", "💀"), ("neutral", "😐"),
        ("sleeping", "😴"), ("sleepy", "😴"), ("vomit", "🤮"), ("puke", "🤮"), ("partying", "🥳"), ("party face", "🥳"),
        ("thumbs up", "👍"), ("thumbs down", "👎"), ("clapping", "👏"), ("clap", "👏"), ("praying", "🙏"), ("pray", "🙏"),
        ("folded hands", "🙏"), ("thank you hands", "🙏"), ("fire", "🔥"), ("red heart", "❤️"), ("heart", "❤️"), ("broken heart", "💔"),
        ("hundred", "💯"), ("100", "💯"), ("party", "🎉"), ("tada", "🎉"), ("celebration", "🎉"), ("check", "✅"), ("tick", "✅"),
        ("cross", "❌"), ("rocket", "🚀"), ("eyes", "👀"), ("wave", "👋"), ("waving", "👋"), ("muscle", "💪"), ("flex", "💪"),
        ("ok hand", "👌"), ("peace", "✌️"), ("star", "⭐"), ("sparkles", "✨"), ("poop", "💩"), ("money", "💰"), ("beer", "🍺"),
        ("coffee", "☕"), ("pizza", "🍕"), ("cake", "🎂"), ("sun", "☀️"), ("rain", "🌧️"), ("dog", "🐶"), ("cat", "🐱"),
    ].sorted { $0.0.count > $1.0.count }
    private static let emoji: NSRegularExpression = {
        let names = emojiNames.map { NSRegularExpression.escapedPattern(for: $0.0).replacingOccurrences(of: " ", with: #"[\s,\-]+"#) }.joined(separator: "|")
        return rx("(?i)\\s*[,.]?\\s*\\b(?:(?:a|an|the)\\s+)?(" + names + ")[\\s,\\-]+emojis?\\b[,.]?")
    }()

    static func applyEmoji(_ text: String) -> String {
        var t = text
        while let m = emoji.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let whole = Range(m.range, in: t), let name = Range(m.range(at: 1), in: t) {
            let key = t[name].lowercased().replacingOccurrences(of: #"[\s,\-]+"#, with: " ", options: .regularExpression)
            let glyph = emojiNames.first { $0.0 == key }?.1 ?? ""
            let before = t[..<whole.lowerBound]
            t.replaceSubrange(whole, with: (before.isEmpty || before.last!.isWhitespace ? "" : " ") + glyph)
        }
        return t
    }

    // MARK: Spoken numbers ("two billion dollars" -> "$2 billion", "one point five billion" -> "1.5 billion")

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Double] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000, "trillion": 1_000_000_000_000]
    private static let bigScales = ["million", "billion", "trillion"]

    static func applyNumbers(_ text: String) -> String {
        // Work on whitespace-separated tokens, keeping the original separators so line breaks survive.
        var tokens = text.components(separatedBy: " ")
        var i = 0
        while i < tokens.count {
            guard let (value, hasDecimal, lastScale, consumed) = parseNumber(tokens, from: i) else { i += 1; continue }
            var end = i + consumed
            let trailing = trailingPunctuation(tokens[i + consumed - 1])
            var unit = ""
            let next = end < tokens.count ? tokens[end].lowercased().trimmingCharacters(in: .punctuationCharacters) : ""
            let nextTrail = end < tokens.count ? trailingPunctuation(tokens[end]) : ""
            if next == "dollars" || next == "dollar" || next == "bucks" { unit = "$"; end += 1 }
            else if next == "percent" || next == "per" && end + 1 < tokens.count && tokens[end + 1].lowercased().hasPrefix("cent") { unit = "%"; end += next == "per" ? 2 : 1 }
            else if next == "k" { unit = "k"; end += 1 }
            let spokenDigits = tokens[i].first?.isNumber == true
            let worth = value >= 10 || hasDecimal || !unit.isEmpty || lastScale != nil || spokenDigits
            guard worth, !(spokenDigits && unit.isEmpty && lastScale == nil) else { i += 1; continue }
            var body: String
            if let scale = lastScale, bigScales.contains(scale) {
                let n = value / scales[scale]!
                body = (n == n.rounded() ? String(Int(n)) : String(format: "%g", n)) + " " + scale
            } else {
                body = hasDecimal ? String(format: "%g", value) : formatInt(Int(value))
            }
            var replacement = unit == "$" ? "$" + body : body + (unit == "%" || unit == "k" ? unit : "")
            replacement += (unit.isEmpty ? String(trailing) : String(nextTrail))
            tokens.replaceSubrange(i..<end, with: [replacement])
            i += 1
        }
        return tokens.joined(separator: " ")
    }

    /// Parses number words starting at `from`: returns value, whether a decimal point was spoken, the last big
    /// scale word ("billion"), and how many tokens were consumed. Digits like "1.5" or "20" count too.
    private static func parseNumber(_ tokens: [String], from: Int) -> (Double, Bool, String?, Int)? {
        var i = from
        var total = 0.0, current = 0.0
        var hasDecimal = false, lastScale: String?, sawWord = false, decimalScale = 0.1
        var afterPoint = false
        func word(_ k: Int) -> String { tokens[k].lowercased().trimmingCharacters(in: .punctuationCharacters) }
        if let d = Double(word(i).replacingOccurrences(of: ",", with: "")), !word(i).isEmpty {
            total = d; hasDecimal = word(i).contains("."); i += 1; sawWord = true
            if i < tokens.count, let sc = scales[word(i)], bigScales.contains(word(i)) { total *= sc; lastScale = word(i); i += 1 }
            return (total, hasDecimal, lastScale, i - from)
        }
        while i < tokens.count {
            let w = word(i)
            if afterPoint {
                if let n = smallNumbers[w], n < 10 { total += Double(n) * decimalScale; decimalScale /= 10; i += 1; continue }
                if let sc = scales[w], bigScales.contains(w) { total *= sc; lastScale = w; i += 1 }
                break
            }
            if w == "a" || w == "an", i + 1 < tokens.count, scales[word(i + 1)] != nil { current = 1; i += 1; sawWord = true; continue }
            if let n = smallNumbers[w] { current += Double(n); i += 1; sawWord = true; continue }
            if let sc = scales[w] {
                if !sawWord { return nil }
                if w == "hundred" { current = (current == 0 ? 1 : current) * sc } else { total += (current == 0 ? 1 : current) * sc; current = 0; lastScale = bigScales.contains(w) ? w : nil }
                i += 1; continue
            }
            if w == "and", sawWord, i + 1 < tokens.count, smallNumbers[word(i + 1)] != nil || scales[word(i + 1)] != nil { i += 1; continue }
            if w == "point", sawWord, i + 1 < tokens.count, let n = smallNumbers[word(i + 1)], n < 10 { afterPoint = true; hasDecimal = true; total += current; current = 0; i += 1; continue }
            break
        }
        guard sawWord else { return nil }
        // The tokens after a decimal must not end on "point"; a dangling "and" was not consumed.
        total += current
        return (total, hasDecimal, lastScale, i - from)
    }

    private static func trailingPunctuation(_ s: String) -> String {
        String(s.reversed().prefix { $0 == "," || $0 == "." || $0 == "?" || $0 == "!" }.reversed())
    }

    private static func formatInt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","; f.usesGroupingSeparator = n >= 10_000
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func applyCommands(_ text: String) -> String {
        var t = applyNumbers(applyEmoji(text))
        for (r, rep) in commands { t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: rep) }
        // Second pass turns the " dot xx" runs left by the email/url templates into ".xx".
        t = dot.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: ".$1")
        return t.replacingOccurrences(of: " \n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Fillers and stutters (before the model, never in verbatim)

    private static let filler = rx(#"(?i)(^|[\s,])(um+|uh+|uhm|erm?|hmm+|mm+)\b[,.]?\s*"#)
    private static let stutter = rx(#"(?i)\b(\w+)([,.]?\s+)\1\b(?=[\s,.!?]|$)"#)

    /// "scratch that" / "forget that" / "never mind" throw away what was said just before it: the unfinished
    /// sentence it sits in, or, when the transcriber already closed that sentence ("She's awful. Never mind."), the
    /// whole previous sentence.
    private static let scratchSignal = rx(#"(?i)\b(?:actually\s+)?(?:scratch that|forget that|never ?mind)\b[,.!?]?\s*"#)
    private static let terminators: Set<Character> = [".", "!", "?"]

    static func applyScratch(_ text: String) -> String {
        var t = text
        while let m = scratchSignal.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range, in: t) {
            let chars = Array(t[..<r.lowerBound])
            var i = chars.count
            while i > 0, chars[i - 1].isWhitespace { i -= 1 }
            let sentenceStart = i == 0 || terminators.contains(chars[i - 1])
            if sentenceStart, i > 0 { i -= 1 }                      // step over the terminator to reach the sentence before
            while i > 0, !terminators.contains(chars[i - 1]) { i -= 1 }   // back to the previous sentence end
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            t = String(chars[..<i]) + t[r.upperBound...]
        }
        return t
    }

    /// "she actually he", "tuesday actually thursday", "five actually six": when the words on both sides of a
    /// correction signal are the same kind of thing, keep the second one. Deliberately narrow so "it's actually good"
    /// is left alone.
    private static let swapClasses: [Set<String>] = [
        ["he", "she", "they", "him", "her", "them", "his", "hers", "their", "i", "we", "you", "me", "us"],
        ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"],
        ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"],
        ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"],
        ["morning", "afternoon", "evening", "tonight", "today", "tomorrow", "yesterday"],
    ]
    private static let swap = rx(#"(?i)\b([\w']+)[,.]?\s+(?:actually|no|sorry|i mean)[,.]?\s+([\w']+)\b"#)

    static func applySwaps(_ text: String) -> String {
        var t = text
        var from = 0
        while true {
            let ns = t as NSString
            guard from < ns.length, let m = swap.firstMatch(in: t, range: NSRange(location: from, length: ns.length - from)) else { break }
            let x = ns.substring(with: m.range(at: 1)).lowercased(), y = ns.substring(with: m.range(at: 2))
            let yl = y.lowercased()
            let sameClass = x != yl && (swapClasses.contains { $0.contains(x) && $0.contains(yl) } || (Int(x) != nil && Int(yl) != nil))
            if sameClass {
                t = ns.replacingCharacters(in: m.range, with: y)
                from = m.range.location + (y as NSString).length
            } else {
                from = m.range.location + 1
            }
        }
        return t
    }

    /// Restarts: "because banking people are heaps more, sorry, because startup people are heaps more genuine" ->
    /// the words after the signal repeat the start of the abandoned clause, so the abandoned clause goes.
    private static let restartSignal = rx(#"(?i)[,.]?\s*\b(?:sorry|no[,\s]+wait|wait[,\s]+no|i mean|correction|let me rephrase)\b[,.]?\s*"#)
    private static let word = rx(#"[^\s]+"#)
    private static let starters: Set<String> = ["because", "so", "and", "but", "if", "when", "then", "can", "could", "would", "should",
                                                "i", "we", "you", "he", "she", "they", "it", "the", "to", "let's", "please", "send", "tell"]

    static func applyRestarts(_ text: String) -> String {
        var t = text
        var from = 0
        while true {
            let ns = t as NSString
            guard from < ns.length, let sig = restartSignal.firstMatch(in: t, range: NSRange(location: from, length: ns.length - from)) else { break }
            // Words of the same sentence before the signal (last 12), and up to 6 after it.
            var before = word.matches(in: t, range: NSRange(location: 0, length: sig.range.location)).map { $0.range }
            if let end = before.lastIndex(where: { r in
                let w = ns.substring(with: r); return w.hasSuffix(".") || w.hasSuffix("!") || w.hasSuffix("?")
            }) { before = Array(before[(end + 1)...]) }
            before = Array(before.suffix(12))
            let afterStart = sig.range.location + sig.range.length
            let after = word.matches(in: t, range: NSRange(location: afterStart, length: ns.length - afterStart)).prefix(6).map { $0.range }
            func norm(_ r: NSRange) -> String { ns.substring(with: r).lowercased().trimmingCharacters(in: .punctuationCharacters) }
            var bestK = -1, bestLen = 0
            for k in before.indices {
                var len = 0
                while k + len < before.count, len < after.count, norm(before[k + len]) == norm(after[len]) { len += 1 }
                if len > bestLen { bestLen = len; bestK = k }
            }
            let accept = bestLen >= 2 || (bestLen == 1 && starters.contains(norm(before[bestK])))
            if accept {
                let start = before[bestK].location
                t = ns.replacingCharacters(in: NSRange(location: start, length: afterStart - start), with: "")
                from = start
            } else {
                from = afterStart
            }
        }
        return t
    }

    /// Restart without a signal word: a phrase of 3+ words said again after a garbled false start
    /// ("i have a thesing what thief i have a few things" -> "i have a few things"). The gap must be short and
    /// must not end in a conjunction, so "we ship on thursday and we ship on friday" is left alone.
    private static let conjunctions: Set<String> = ["and", "or", "but", "then", "so", "because", "if", "when"]

    private static let articleRestart = rx(#"(?i)(^|(?<!\b(?:the|a|an|of|in|on|at|by|to|for)\s)\b)(\w+)[,]?\s+(a|an|the)\s+\2\b"#)

    static func applyRepeats(_ text: String) -> String {
        let ns = text as NSString
        let words = word.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range }
        func norm(_ r: NSRange) -> String { ns.substring(with: r).lowercased().trimmingCharacters(in: .punctuationCharacters) }
        guard words.count >= 6 else { return text }
        for i in 0..<(words.count - 5) {
            for gap in 0...4 {
                let j = i + 3 + gap
                guard j + 2 < words.count else { continue }
                if norm(words[i]) == norm(words[j]), norm(words[i + 1]) == norm(words[j + 1]), norm(words[i + 2]) == norm(words[j + 2]),
                   !conjunctions.contains(norm(words[j - 1])), !norm(words[i]).isEmpty {
                    let cut = NSRange(location: words[i].location, length: words[j].location - words[i].location)
                    return applyRepeats(ns.replacingCharacters(in: cut, with: ""))
                }
            }
        }
        return text
    }

    static func stripFillers(_ text: String) -> String {
        var t = applySwaps(applyRepeats(applyRestarts(applyScratch(text))))
        // "this is fair a fair bit of work" -> "this is a fair bit of work": a word restarted with its article.
        t = articleRestart.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1$3 $2")
        t = filler.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        // Run twice so "we we we" collapses fully.
        for _ in 0..<2 { t = stutter.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1") }
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[,\s]+"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Casual fast path

    /// lowercase with light punctuation: the transcriber's commas and full stops stay, except at the very end and
    /// after laughter; no exclamation marks. Dictionary terms keep their spelling.
    /// casual: lowercase sentence starts and "i", the transcriber's commas and full stops kept (including the last).
    /// super casual: no commas, full stops only between sentences, none at the end.
    static func casual(_ text: String, keeping terms: [String] = [], superCasual: Bool = false) -> String {
        // Lowercase sentence starts and "I", keep the transcriber's capitals on names (Alex, Instagram).
        var t = lowercaseSentenceStarts(text)
        t = t.replacingOccurrences(of: #"\bI\b"#, with: "i", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[!;:]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(haha+|lol|lmao)[.,]"#, with: "$1", options: .regularExpression)
        if superCasual { t = t.replacingOccurrences(of: ",", with: "") }
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if superCasual { while t.hasSuffix(".") || t.hasSuffix(",") { t.removeLast() } }
        for term in terms where term.count >= 3 {
            t = t.replacingOccurrences(of: term.lowercased(), with: term)
        }
        return t
    }

    private static func lowercaseSentenceStarts(_ text: String) -> String {
        var out = ""
        var atStart = true
        for ch in text {
            if atStart, ch.isLetter { out.append(contentsOf: ch.lowercased()); atStart = false; continue }
            if ch == "." || ch == "?" || ch == "!" { atStart = true } else if !ch.isWhitespace { atStart = false }
            out.append(ch)
        }
        return out
    }

    // MARK: Layout touch-up (after the model)

    private static let messageGreeting = rx(#"(?i)^((?:dear|hi|hey|hello|good morning|good afternoon|good evening|morning|afternoon|evening)\b(?:[^,.!\n]{0,40}[,.!]|\s+[A-Za-z][\w'-]*(?=\s)))\s*"#)
    private static let messageSignoff = rx(#"(?i)\s+((?:kind regards|best regards|warm regards|warmest regards|regards|cheers|many thanks|thanks|thank you|best|all the best|talk soon|take care|speak soon)[,.]?)(?:\s+([A-Za-z][\w'-]*(?:\s+[A-Za-z][\w'-]*)?))?[.]?\s*$"#)

    /// A dictation that opens with a greeting and closes with a sign-off is a message: lay it out as one in every
    /// tone (greeting line, blank line, body, blank line, sign-off, name). The model often leaves it as one run-on
    /// line in casual tone.
    static func layoutMessage(_ text: String) -> String {
        guard !text.contains("\n"),
              let g = messageGreeting.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let greeting = Range(g.range(at: 1), in: text), let afterGreeting = Range(g.range, in: text),
              let so = messageSignoff.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let signoffRange = Range(so.range, in: text), let signoff = Range(so.range(at: 1), in: text),
              signoffRange.lowerBound > afterGreeting.upperBound else { return text }
        var body = text[afterGreeting.upperBound..<signoffRange.lowerBound].trimmingCharacters(in: .whitespaces)
        if body.hasSuffix(",") { body.removeLast() }
        guard body.split(separator: " ").count >= 2 else { return text }
        var out = text[greeting] + "\n\n" + body + "\n\n" + text[signoff]
        if let name = Range(so.range(at: 2), in: text) { out += "\n" + text[name] }
        return out
    }

    /// The model sometimes repeats the text that was already before the cursor. Drop such an echo.
    static func stripEcho(_ output: String, before: String) -> String {
        let tail = before.split(separator: " ").suffix(12).map(String.init)
        guard tail.count >= 4 else { return output }
        let outWords = output.split(separator: " ").map(String.init)
        func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let t = tail.map(norm), o = outWords.map(norm)
        for n in stride(from: min(t.count, o.count), through: 4, by: -1) {
            for j in 0...min(2, o.count - n) where Array(t.suffix(n)) == Array(o[j..<(j + n)]) {
                return outWords.dropFirst(j + n).joined(separator: " ")
            }
        }
        return output
    }

    private static let greeting = rx(#"(?i)^((?:hi|hey|hello|dear|good morning|good afternoon|good evening|morning|afternoon|evening)\b(?:[^,.!\n]{0,40}[,.!]|\s+[A-Za-z][\w'-]*(?=\s)))\s+(?=\S)"#)

    /// If the model laid the text out as a message (there is a paragraph break) but left the greeting glued to the
    /// first sentence, put the greeting on its own line.
    static func layoutGreeting(_ text: String) -> String {
        guard text.contains("\n\n"), let m = greeting.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let head = Range(m.range(at: 1), in: text), let whole = Range(m.range, in: text) else { return text }
        let rest = text[whole.upperBound...]
        let capitalised = text[head].first?.isUppercase == true      // casual tone stays lowercase
        return text[head] + "\n\n" + (capitalised ? rest.prefix(1).uppercased() : String(rest.prefix(1))) + rest.dropFirst()
    }

    /// Spoken enumerations ("firstly ..., secondly ..., thirdly ...", "number one ...", "first, ... second, ...")
    /// become a bullet list when there are at least two markers. Runs after the model in every tone.
    private static let listMarker = rx(#"(?i)(^|[.,;:!?]\s*|\s)(?:(?:firstly|secondly|thirdly|fourthly|fifthly|first of all|second of all|number (?:one|two|three|four|five|six))|(?<=[.,;:!?]\s)(?:first|second|third|fourth|fifth)|^(?:first|second|third))\b[,:]?\s*"#)

    static func applyLists(_ text: String) -> String {
        let matches = listMarker.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count >= 2 else { return text }
        var t = text as NSString
        for m in matches.reversed() {
            let lead = t.substring(with: m.range(at: 1))
            let keep = lead.trimmingCharacters(in: .whitespaces)          // the punctuation that ended the previous clause
            t = t.replacingCharacters(in: m.range, with: (keep.isEmpty ? "" : keep) + "\n- ") as NSString
        }
        return (t as String).replacingOccurrences(of: #"[,;]\n- "#, with: ".\n- ", options: .regularExpression)
            .replacingOccurrences(of: #"^\n- "#, with: "- ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a missing "?" to sentences that are unmistakably questions by their opening words.
    private static let questionStart = rx(#"(?i)^(?:(?:are|can|could|do|does|did|is|will|would|should|shall|have|has|were|was|am)\s+(?:you|we|i|it|there|they|he|she|this|that|anyone|someone)\b|(?:what|when|where|who|why|how)['’](?:s|re|d|ll)\s+\w+|(?:what|when|where|who|why|how)\s+(?:is|are|do|does|did|can|could|will|would|should|have|has|was|were|about|time|many|much|long)\b)"#)

    static func questionMarks(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var out = ""
            var sentence = ""
            func flush(_ terminator: Character?) {
                var body = sentence.trimmingCharacters(in: .whitespaces)
                body = body.replacingOccurrences(of: #"^(?:- |\d+[.)] )"#, with: "", options: .regularExpression)   // list bullets
                let isQuestion = questionStart.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
                if isQuestion, terminator == nil || terminator == "." { out += sentence + "?" }
                else { out += sentence + (terminator.map(String.init) ?? "") }
                sentence = ""
            }
            for ch in line {
                if ch == "." || ch == "?" || ch == "!" { flush(ch) } else { sentence.append(ch) }
            }
            if !sentence.trimmingCharacters(in: .whitespaces).isEmpty { flush(nil) }
            return out
        }.joined(separator: "\n")
    }

    // MARK: Dictionary (names and jargon, with sound-alikes)

    /// A dictionary line is "Term" or "Term: sound-alike, sound-alike" (also "=" or parentheses).
    static func parseDictionary(_ lines: [String]) -> [(term: String, aliases: [String])] {
        lines.compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { return nil }
            var term = l, rest = ""
            if let r = l.range(of: #"\s*[:=]\s*"#, options: .regularExpression) { term = String(l[..<r.lowerBound]); rest = String(l[r.upperBound...]) }
            else if let r = l.range(of: #"\s*\((.*)\)\s*$"#, options: .regularExpression) { term = String(l[..<r.lowerBound]); rest = String(l[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ()")) }
            let aliases = rest.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (term.trimmingCharacters(in: .whitespaces), aliases)
        }
    }

    static func dictionaryTerms(_ lines: [String]) -> [String] { parseDictionary(lines).map(\.term) }

    /// Replaces sound-alikes with the term, and fixes the term's own capitalisation. Whole words only.
    static func applyDictionary(_ text: String, _ lines: [String]) -> String {
        var t = text
        for e in parseDictionary(lines) {
            let variants = ([e.term] + e.aliases).sorted { $0.count > $1.count }
            for v in variants where v.count >= 2 {
                let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: v).replacingOccurrences(of: "\\ ", with: "[\\s-]*") + "\\b"
                t = t.replacingOccurrences(of: pattern, with: e.term, options: .regularExpression)
            }
        }
        return t
    }

    // MARK: Learning names

    private static let commonCapitalised: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "the", "a", "an", "and", "but", "or", "so", "hi", "hey", "hello", "dear", "thanks", "thank", "cheers",
        "kind", "best", "regards", "yes", "no", "ok", "okay", "yeah", "also", "please", "sorry", "just", "well", "oh", "wow", "haha", "lol",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december", "today", "tomorrow", "yesterday", "morning", "afternoon", "evening",
        "this", "that", "these", "those", "there", "here", "what", "when", "where", "who", "why", "how", "it", "it's", "we", "we're", "you",
        "he", "she", "they", "my", "your", "our", "his", "her", "their", "if", "in", "on", "at", "to", "for", "of", "with", "from", "by",
        "not", "can", "could", "would", "should", "will", "do", "does", "did", "is", "are", "was", "were", "be", "been", "have", "has", "had",
        "let's", "let", "hope", "see", "send", "get", "got", "one", "two", "three", "first", "second", "third", "new", "re", "fw", "fwd",
        "window", "untitled", "all", "notes", "messages", "mail", "chrome", "safari", "google", "search", "inbox", "sent", "draft",
    ]

    /// Capitalised words and phrases in `text` that look like names, in order of appearance ("Wispr Flow", "Zentro").
    static func contextNames(_ text: String, limit: Int = 15) -> [String] {
        let words = text.split { $0.isWhitespace }.map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-"))) }
        let lower = Set(words.filter { $0.first?.isLowercase == true }.map { $0.lowercased() })
        func isName(_ w: String) -> Bool {
            guard w.count >= 3, let f = w.first, f.isUppercase, w.dropFirst().contains(where: { $0.isLetter }),
                  !commonCapitalised.contains(w.lowercased()), !lower.contains(w.lowercased()) else { return false }
            return true
        }
        var out: [String] = []
        var i = 0
        while i < words.count {
            guard isName(words[i]) else { i += 1; continue }
            var phrase = [words[i]]
            var j = i + 1
            while j < words.count, phrase.count < 3, isName(words[j]) { phrase.append(words[j]); j += 1 }
            let name = phrase.joined(separator: " ")
            if !out.contains(where: { $0.lowercased() == name.lowercased() }) { out.append(name) }
            i = j
        }
        return Array(out.prefix(limit))
    }

    /// What a correction teaches: (term, sound-alike) pairs where the user replaced a span of the transcript with a
    /// capitalised name. "i've done zentrow" -> "i've done Zentro" gives ("Zentro", "zentrow").
    static func learnNames(heard: String, corrected: String) -> [(term: String, alias: String)] {
        func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’"))) }
        let a = heard.split { $0.isWhitespace }.map(String.init), b = corrected.split { $0.isWhitespace }.map(String.init)
        guard !a.isEmpty, !b.isEmpty, a.count < 400, b.count < 400 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = norm(a[i]) == norm(b[j]) ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [(String, String)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if norm(a[i]) == norm(b[j]) { i += 1; j += 1; continue }
            // A differing region: advance both sides until the LCS resumes.
            var ai = i, bj = j
            while ai < a.count || bj < b.count {
                if ai < a.count, bj < b.count, norm(a[ai]) == norm(b[bj]), dp[ai][bj] == dp[ai + 1][bj + 1] + 1 { break }
                if ai < a.count, dp[ai][bj] == dp[ai + 1][bj] { ai += 1; continue }
                if bj < b.count, dp[ai][bj] == dp[ai][bj + 1] { bj += 1; continue }
                break
            }
            // A name can continue with words that were heard right ("whisper flow" -> "Wispr Flow"): extend the
            // span while both sides agree and the corrected word is capitalised.
            var heardEnd = ai, fixedEnd = bj
            while heardEnd < a.count, fixedEnd < b.count, norm(a[heardEnd]) == norm(b[fixedEnd]), fixedEnd - j < 3,
                  b[fixedEnd].first?.isUppercase == true, !commonCapitalised.contains(norm(b[fixedEnd])) { heardEnd += 1; fixedEnd += 1 }
            let heardSpan = a[i..<heardEnd].map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
            let fixedSpan = b[j..<fixedEnd].map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-"))) }.filter { !$0.isEmpty }
            if !heardSpan.isEmpty, !fixedSpan.isEmpty, heardSpan.count <= 4, fixedSpan.count <= 3,
               fixedSpan.allSatisfy({ $0.first?.isUppercase == true && !commonCapitalised.contains($0.lowercased()) }) {
                let term = fixedSpan.joined(separator: " "), alias = heardSpan.joined(separator: " ").lowercased()
                if term.lowercased() != alias, term.count >= 3 { out.append((term, alias)) }
            }
            i = heardEnd; j = fixedEnd
        }
        return out
    }

    /// Correction phrases a correction reveals: when the user deleted a run of words that ends in a short aside
    /// ("Vegemite toast i know" -> gone, "kfc for lunch" kept), the aside ("i know") is how their "no wait" gets
    /// heard. Returns lowercased 1-2 word phrases.
    static func learnSignals(heard: String, corrected: String) -> [String] {
        func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’"))) }
        let a = heard.split { $0.isWhitespace }.map(String.init), b = corrected.split { $0.isWhitespace }.map(String.init)
        guard a.count >= 4, !b.isEmpty, a.count < 400, b.count < 400 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = norm(a[i]) == norm(b[j]) ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < a.count {
            if j < b.count, norm(a[i]) == norm(b[j]) { i += 1; j += 1; continue }
            if j < b.count, dp[i][j] == dp[i][j + 1] { j += 1; continue }
            // a[i] was deleted: collect the whole deleted run
            var k = i
            while k < a.count, !(j < b.count && norm(a[k]) == norm(b[j]) && dp[k][j] == dp[k + 1][j + 1] + 1) { k += 1 }
            let run = a[i..<k].map(norm).filter { !$0.isEmpty }
            // A deleted run of 3+ words whose tail is a short aside that was followed by kept text.
            if run.count >= 3, k < a.count {
                for n in [2, 1] where run.count > n {
                    let tail = run.suffix(n).joined(separator: " ")
                    if !commonCapitalised.contains(tail) || n == 2 { out.append(tail); break }
                }
            }
            i = k
        }
        return out
    }

    /// Adds learned pairs to dictionary lines, merging sound-alikes into an existing term.
    static func mergeDictionary(_ lines: [String], learned: [(term: String, alias: String)]) -> [String] {
        var lines = lines
        for (term, alias) in learned {
            if let idx = lines.firstIndex(where: { parseDictionary([$0]).first?.term.lowercased() == term.lowercased() }) {
                let e = parseDictionary([lines[idx]]).first!
                if !e.aliases.contains(where: { $0.lowercased() == alias }) { lines[idx] = e.term + ": " + (e.aliases + [alias]).joined(separator: ", ") }
            } else {
                lines.append(term + ": " + alias)
            }
        }
        return lines
    }

    // MARK: Counted lists ("three things: a, b, c" -> numbered list)

    private static let countedLead = rx(#"(?i)\b(two|three|four|five|six|2|3|4|5|6)\s+(things|reasons|points|steps|options|ways|issues|updates|questions|items|ideas|problems|tips|takeaways|decisions|requests|asks)\b([^:.\n]{0,80})[:.]\s*"#)
    private static let countWords = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6]

    /// "there are three things it does well: it's fast, it's accurate, it gets names right." becomes the lead-in
    /// followed by a numbered list, when the items after the colon really split into that many.
    static func applyCountedLists(_ text: String) -> String {
        guard !text.contains("\n1.") && !text.contains("\n- "),
              let m = countedLead.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(m.range, in: text), let countRange = Range(m.range(at: 1), in: text),
              let n = countWords[text[countRange].lowercased()] else { return text }
        // Items run to the end of the sentence that follows the colon.
        let rest = String(text[whole.upperBound...])
        var body = rest, tail = ""
        if let end = rest.range(of: #"[.!?](?=\s|$)|\n"#, options: .regularExpression) {
            body = String(rest[..<end.lowerBound])
            tail = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        var items = body.replacingOccurrences(of: #"\s*;\s*"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #",\s*(and|or)\s+"#, with: ",", options: .regularExpression)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if items.count == n - 1, let last = items.last, let r = last.range(of: #"\s+(and|or)\s+"#, options: .regularExpression) {
            items[items.count - 1] = String(last[..<r.lowerBound]); items.append(String(last[r.upperBound...]))
        }
        guard items.count == n else { return text }
        var lead = text[..<whole.upperBound].trimmingCharacters(in: .whitespaces)
        if lead.hasSuffix(".") { lead.removeLast(); lead += ":" }
        if !tail.isEmpty { tail = "\n" + tail }
        return lead + "\n" + items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + tail
    }

    // MARK: Guardrail (after the model)

    /// True when the model's output looks like a rewrite or hallucination rather than a cleanup of `input`.
    static func looksUnfaithful(input: String, output: String, allowed: [String]) -> Bool {
        let inWords = words(input)
        let outWords = words(output)
        guard inWords.count >= 6 else { return false }             // too short to judge
        let ratio = Double(outWords.count) / Double(inWords.count)
        if ratio < 0.35 || ratio > 1.6 { return true }
        let allowedWords = Set(allowed.flatMap { words($0) })
        let inSet = Set(inWords)
        let novel = outWords.filter { !inSet.contains($0) && !allowedWords.contains($0) && $0.count > 3 }
        return Double(novel.count) / Double(max(outWords.count, 1)) > 0.3
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: []) }

    // MARK: Scoring (used by --eval)

    /// Word error rate of `hypothesis` against `reference`, ignoring case and punctuation. 0 = identical words.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) where h.count > 0 {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
