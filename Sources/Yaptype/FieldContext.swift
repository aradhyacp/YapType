import AppKit
import ApplicationServices

/// What the user is typing into, read through the Accessibility API at the moment the hotkey goes down.
/// Only used to interpret the dictation (names, whether it continues a sentence); it is never logged.
struct FieldContext {
    /// Title of the frontmost window, which usually names the thread or document ("Alex", "#design", "Re: invoice").
    var windowTitle = ""
    /// Text in the focused field before the cursor, trimmed to the tail.
    var before = ""
    /// Text in the focused field after the cursor.
    var after = ""
    /// Cursor position in UTF-16 units, when the field reported it.
    var cursor: Int?

    var isEmpty: Bool { windowTitle.isEmpty && before.isEmpty && after.isEmpty }

    /// True when the cursor sits right after a non-space character, so pasted text needs a leading space.
    var needsLeadingSpace: Bool {
        guard let last = before.last else { return false }
        return !last.isWhitespace && !last.isNewline
    }

    static func capture() -> FieldContext {
        var ctx = FieldContext()
        guard let app = NSWorkspace.shared.frontmostApplication else { return ctx }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute),
           let title: String = attribute(window, kAXTitleAttribute) {
            ctx.windowTitle = String(title.prefix(120))
        }
        guard let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute),
              let value: String = attribute(focused, kAXValueAttribute), !value.isEmpty else { return ctx }
        let units = Array(value.utf16)
        var cursor = units.count
        if let rangeValue: AXValue = attribute(focused, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) { cursor = min(max(range.location, 0), units.count); ctx.cursor = cursor }
        }
        ctx.before = String(utf16CodeUnits: Array(units[..<cursor].suffix(3000)), count: min(cursor, 3000))
        ctx.after = String(utf16CodeUnits: Array(units[cursor...].prefix(600)), count: min(units.count - cursor, 600))
        return ctx
    }

    /// Replaces `length` UTF-16 units at `location` in the focused field with `text` through Accessibility, in one
    /// operation and without keystrokes. Returns false when the field doesn't support it or the result doesn't
    /// read back as expected, so the caller can fall back to keystrokes.
    /// Only Apple's own text views are trusted with this: browsers and Electron apps report the attributes as
    /// settable but apply them in surprising ways (one app inserted the text nine times).
    static func replace(location: Int, length: Int, expecting live: String, with text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, (app.bundleIdentifier ?? "").hasPrefix("com.apple.") else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue,
              AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        guard let current: String = attribute(focused, kAXValueAttribute), location + length <= current.utf16.count else { return false }
        let liveUnits = Array(current.utf16[current.utf16.index(current.utf16.startIndex, offsetBy: location)..<current.utf16.index(current.utf16.startIndex, offsetBy: location + length)])
        _ = live
        func setRange(_ loc: Int, _ len: Int) -> Bool {
            var r = CFRange(location: loc, length: len)
            guard let v = AXValueCreate(.cfRange, &r) else { return false }
            return AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, v) == .success
        }
        guard setRange(location, length) else { return false }
        let inserted = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        // Read back: the text must now sit at `location`.
        let value: String = attribute(focused, kAXValueAttribute) ?? ""
        let units = Array(value.utf16), t = Array(text.utf16)
        let ok = inserted && location + t.count <= units.count && Array(units[location..<(location + t.count)]) == t
        if ok {
            _ = setRange(location + t.count, 0)                 // caret after the inserted text
            return true
        }
        // Undo any half-applied state for the keystroke fallback: caret back at the end of the live text if it is
        // still there, so backspaces remove exactly the live text and nothing else.
        if location + liveUnits.count <= units.count, Array(units[location..<(location + liveUnits.count)]) == liveUnits {
            _ = setRange(location + liveUnits.count, 0)
        }
        return false
    }

    static func debug() -> String {
        var out: CFTypeRef?
        guard let app = NSWorkspace.shared.frontmostApplication else { return "no frontmost app" }
        print("frontmost: \(app.bundleIdentifier ?? "?") pid \(app.processIdentifier)")
        let e1 = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &out)
        guard e1 == .success, let el = out else { return "focused element error \(e1.rawValue)" }
        let focused = el as! AXUIElement
        var role: CFTypeRef?; var value: CFTypeRef?
        let e2 = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
        let e3 = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value)
        return "role=\(role.map { "\($0)" } ?? "nil") (\(e2.rawValue)) value type=\(value.map { String(describing: type(of: $0)) } ?? "nil") (\(e3.rawValue)) len=\((value as? String)?.count ?? -1)"
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success, let out else { return nil }
        return out as? T
    }
}
