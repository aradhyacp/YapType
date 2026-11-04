import AppKit
import os

/// Global event tap that watches the hotkey (Cmd + keyCode, Cmd+Shift for alt) and Escape.
/// The hotkey events are swallowed so the frontmost app never sees them.
/// Needs the Accessibility permission; keeps retrying until it's granted.
final class HotkeyMonitor {
    var onPress: (@MainActor (_ alt: Bool) -> Void)?
    var onRelease: (@MainActor () -> Void)?
    var onEscape: (@MainActor () -> Void)?
    /// Escape is only swallowed (and reported) while this returns true.
    var isRecording: (@MainActor () -> Bool)?

    private let keyCode: UInt16
    private var tap: CFMachPort?
    private let log = Logger(subsystem: "com.yaptype.app", category: "hotkey")

    init(keyCode: UInt16) {
        self.keyCode = keyCode
    }

    func start() {
        if tap != nil { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            log.warning("Event tap unavailable (Accessibility not granted yet); retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("Event tap installed")
    }

    var isRunning: Bool { tap != nil }

    /// The tap callback runs on the main run loop, so it's safe to read main-actor state here.
    private func isRecordingNow() -> Bool {
        MainActor.assumeIsolated { isRecording?() ?? false }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables the tap if we're ever too slow; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if code == 53, type == .keyDown, isRecordingNow() {   // Escape
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onEscape?() } }
            return nil
        }
        guard code == keyCode else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else {
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            let alt = flags.contains(.maskShift)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onPress?(alt) } }
            return nil
        }
        if type == .keyUp {
            // Release counts even if Cmd was let go first.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onRelease?() } }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
