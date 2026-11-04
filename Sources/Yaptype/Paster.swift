import AppKit

/// Puts text on the clipboard, sends Cmd+V to the frontmost app, then restores what was on the clipboard.
enum Paster {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {   // slow apps consume ⌘V late; don't paste the old clipboard
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }
}
