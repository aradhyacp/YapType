import AppKit
import os

/// Shows the live transcript in the focused field while you talk, then removes it so the polished text can be
/// pasted. Text is inserted by pasting, never by keystrokes: apps autocorrect what is typed (Notes fixes spelling,
/// capitalises, swaps smart punctuation), which made backspace counts drift and eat surrounding text. Pasted text
/// is left alone, so the count of what we inserted stays exact. The Accessibility cursor position is not used
/// for counting either; it proved unreliable mid-edit in Notes.
@MainActor
final class LiveTyper {
    private(set) var typed = ""
    private var savedClipboard: String?
    /// Text before the cursor at begin(), when the field could be read; used to check that the final paste landed.
    private var fieldBefore: String?
    private var cursor: Int?
    private var desynced = false
    private static let source = CGEventSource(stateID: .combinedSessionState)
    private let log = Logger(subsystem: "com.yaptype.app", category: "typer")
    /// Live updates only rewrite this many trailing characters; earlier words stay as first shown (the final swap
    /// fixes everything anyway).
    private let tailWindow = 80

    func begin(context: FieldContext?) {
        typed = ""
        savedClipboard = NSPasteboard.general.string(forType: .string)
        fieldBefore = context.flatMap { $0.before.isEmpty && $0.windowTitle.isEmpty ? nil : $0.before }
        cursor = context?.cursor
        desynced = false
    }

    /// Live hypothesis: trailing punctuation is dropped so a "." that flickers on and off doesn't cause churn.
    func update(_ text: String) async {
        guard !desynced else { return }
        var next = text.replacingOccurrences(of: "\n", with: " ")
        while let last = next.last, last == "." || last == "," || last == " " { next.removeLast() }
        guard next != typed else { return }
        let common = zip(typed, next).prefix { $0 == $1 }.count
        let keep = min(max(common, typed.count - tailWindow), next.count)
        backspace(typed.count - keep)
        typed = String(typed.prefix(keep)) + next.dropFirst(keep)
        if insert(String(next.dropFirst(keep))) {
            // ⌘V is delivered asynchronously; the clipboard must not change until the app has consumed it. Where the
            // field can be read, wait until its length shows the paste landed; if it never does, stop typing live
            // (the final swap measures what is really there).
            if let start = cursor {
                let expected = start + typed.utf16.count
                var landed = false
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let cur = FieldContext.capture().cursor, cur >= expected { landed = true; break }
                }
                if !landed { desynced = true; log.error("Live text out of sync with the field; stopping live typing for this dictation") }
            } else {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    /// The live text's real extent in the field: from where the cursor was at begin() to where it is now.
    private func measuredLive() -> (start: Int, length: Int, text: String)? {
        guard let start = cursor else { return nil }
        let now = FieldContext.capture()
        guard let cur = now.cursor, cur >= start else { return nil }
        let slack = max(8, typed.utf16.count / 5)
        guard cur - start <= typed.utf16.count + slack else { return nil }
        let before = Array(now.before.utf16)                        // suffix of the field up to the cursor
        guard before.count >= cur - start else { return nil }
        let live = String(utf16CodeUnits: Array(before.suffix(cur - start)), count: cur - start)
        return (start, cur - start, live)
    }

    /// Removes exactly what was inserted (cancel, or nothing to paste).
    func retract() async {
        let n = measuredLive()?.text.count ?? typed.count
        log.info("Retract \(n, privacy: .public) chars")
        backspace(n)
        typed = ""
        try? await Task.sleep(for: .seconds(1))
        restoreClipboard()
    }

    /// Replaces the live text with the final text in one go: backspaces, one paste, then the user's clipboard is
    /// put back once the paste has been consumed. A single ordered sequence, so nothing can race the paste.
    func finish(with text: String) async {
        var toRemove = typed.count
        // Where the field can be read, the live text's real extent is measured (from the cursor position at start
        // to the cursor now) instead of trusting what we think we inserted: pastes can land late or get dropped.
        if let m = measuredLive() {
            toRemove = m.text.count
            // Apple's text views can swap the measured range for the final text in one operation: instant, exact.
            if FieldContext.replace(location: m.start, length: m.length, expecting: m.text, with: text) {
                log.info("Finish: replaced \(m.length, privacy: .public) units in place with \(text.count, privacy: .public)")
                typed = ""
                restoreClipboard()
                return
            }
        } else if desynced {
            log.error("Finish: field unreadable after a desync; leaving the live text and appending the final text")
            toRemove = 0
        }
        log.info("Finish: retract \(toRemove, privacy: .public) chars (typed \(self.typed.count, privacy: .public)), paste \(text.count, privacy: .public)")
        backspace(toRemove)
        typed = ""
        insert(text)
        // The paste is delivered asynchronously, behind every backspace above; a slow app can take seconds to get
        // through them. Restoring the clipboard before the paste lands pastes the old clipboard instead. So: wait
        // until the field shows the pasted text where it can be read, otherwise wait in proportion to the queue.
        let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        let deadline = Date().addingTimeInterval(2.0 + Double(toRemove) * 0.03)
        var landed = false
        if fieldBefore != nil, probe.count >= 6 {
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                if FieldContext.capture().before.contains(probe) { landed = true; break }
            }
        }
        if !landed { try? await Task.sleep(until: .now + .seconds(max(0, deadline.timeIntervalSinceNow) + 1.5), clock: .continuous) }
        restoreClipboard()
    }

    /// The inserted text is the final result: stop tracking it.
    func forget() { typed = ""; restoreClipboard() }

    private func restoreClipboard() {
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(saved, forType: .string)
    }

    private func backspace(_ n: Int) {
        guard n > 0 else { return }
        for _ in 0..<n { key(51, flags: []) }
    }

    @discardableResult
    private func insert(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        key(9, flags: .maskCommand)                       // ⌘V
        return true
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: Self.source, virtualKey: code, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
        }
    }
}
