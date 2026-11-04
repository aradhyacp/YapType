import AppKit
import AVFoundation
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case loading, idle, recording, processing, error(String) }

    private let store = Store()
    private var config: Config { store.config }

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var toneMenu: NSMenu!
    private var historyMenu: NSMenu!
    private var settingsWindow: NSWindow?
    private var hotkey: HotkeyMonitor!
    private let recorder = AudioRecorder()
    private let overlay = Overlay()
    private let typer = LiveTyper()
    private var fieldContext: FieldContext?
    private var liveTask: Task<Void, Never>?
    /// Live text goes into the field only where the field can be read back (Accessibility cursor available): that is
    /// what makes the swap exact. Elsewhere (browsers, Electron apps) it shows in the pill and only the final text is
    /// pasted, once.
    private var liveTextAllowed: Bool {
        !(targetBundleID.map { config.liveTextExcluded.contains($0) } ?? false) && fieldContext?.cursor != nil
    }
    private var liveText = ""
    private let transcriber = Transcriber()
    private let log = Logger(subsystem: "com.yaptype.app", category: "app")

    private var state: State = .loading { didSet { render() } }
    private var pressedAt: Date?
    private var toggleMode = false
    private var useAlt = false
    private var targetBundleID: String?
    /// Sticky tone chosen from the menu bar; nil = automatic per app.
    private var toneOverride: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildMenu()
        render()

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { Task { @MainActor in self.state = .error("Microphone permission denied") } }
        }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        hotkey = HotkeyMonitor(keyCode: config.hotkeyKeyCode)
        hotkey.onPress = { [weak self] alt in self?.hotkeyPressed(alt: alt) }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onEscape = { [weak self] in self?.cancelRecording() }
        hotkey.isRecording = { [weak self] in
            if case .recording = self?.state { return true }
            return false
        }
        hotkey.start()
        recorder.onLevel = { [overlay] in overlay.level($0) }

        store.onAsrChange = { [weak self] in Task { await self?.loadTranscriber() } }
        store.onConfigChange = { [weak self] in self?.configChanged() }
        store.polishReady = !config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        render()
        Task { await refreshExternalNames() }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { await self?.refreshExternalNames() } }
        Task { await loadTranscriber() }
        if CommandLine.arguments.contains("--settings") || config.windowAtLaunch { openSettings() }
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    /// Standard menu bar so ⌘C/⌘V/⌘Z work in the window's text fields and ⌘Q/⌘W behave normally.
    private func buildMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Yaptype", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Yaptype", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Yaptype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(); windowItem.submenu = window; main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.shutdown()
    }

    private func refreshExternalNames() async {
        guard config.useContacts else { store.externalNames = []; return }
        let names = await NameSources.names()
        store.externalNames = names
        log.info("Contacts/Calendar names: \(names.count, privacy: .public)")
    }

    // MARK: Engines

    private func loadTranscriber() async {
        store.speechReady = false
        state = .loading
        do {
            try await transcriber.load(version: config.asrVersion)
            store.speechReady = true
            state = .idle
            await transcriber.setVocabulary(config.dictionary)
        } catch {
            log.error("Speech model failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
        }
    }

    private func configChanged() {
        store.polishReady = !config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        render()
    }

    // MARK: Hotkey flow

    private func hotkeyPressed(alt: Bool) {
        switch state {
        case .idle:
            beginRecording(alt: alt)
        case .recording where toggleMode:
            finishRecording()
        default:
            break
        }
    }

    private func hotkeyReleased() {
        guard case .recording = state, let pressedAt else { return }
        if toggleMode { return }
        if Date().timeIntervalSince(pressedAt) < config.tapThreshold {
            toggleMode = true          // quick tap: keep recording until the next tap
            render()
        } else {
            finishRecording()          // held: release ends it
        }
    }

    private func beginRecording(alt: Bool) {
        targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        fieldContext = config.fieldContext ? FieldContext.capture() : nil
        useAlt = alt
        toggleMode = false
        liveText = ""
        typer.begin(context: fieldContext)
        do {
            recorder.preferredDevice = config.microphone
            try recorder.start()
            pressedAt = Date()                       // after start(), so its cost never counts as holding the key
            if config.sounds { Cue.start() }
            state = .recording
            startLive()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Re-decodes the audio so far every few hundred ms so the transcript is ready on release and, if enabled,
    /// appears in the field while talking.
    private func startLive() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            guard let self else { return }
            // Names visible where you're typing (window title, text around the cursor), plus Contacts/Calendar
            // names, are boosted for this dictation.
            let names = fieldContext.map { TextRules.contextNames([$0.windowTitle, $0.before, $0.after].joined(separator: " ")) } ?? []
            await transcriber.setVocabulary(config.dictionary, extra: names + store.externalNames)
            await transcriber.beginLive()
            while !Task.isCancelled, case .recording = state {
                let started = Date()
                let snap = recorder.snapshot()
                if snap.count > 16_000 / 2, let text = try? await transcriber.liveUpdate(snap), !Task.isCancelled {
                    liveText = text
                    if config.liveText, case .recording = state {
                        if liveTextAllowed { await typer.update((fieldContext?.needsLeadingSpace == true ? " " : "") + text) }
                        else { overlay.live(text) }
                    }
                }
                // Aim for an update every ~400 ms including the decode itself; never spin faster than 120 ms.
                let spent = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(max(120, 400 - Int(spent * 1000))))
            }
        }
    }

    private func cancelRecording() {
        guard case .recording = state else { return }
        let samples = recorder.stop()
        log.info("Cancelled after \(samples.count / 16, privacy: .public) ms, peak \(samples.max() ?? 0, privacy: .public)")
        liveTask?.cancel()
        Task { await transcriber.beginLive(); await typer.retract() }
        state = .idle
    }

    private func finishRecording() {
        let samples = recorder.stop()
        if config.sounds { Cue.stop() }
        state = .processing
        let tone = resolveTone()
        let pending = liveTask; liveTask = nil
        Task {
            do {
                pending?.cancel(); _ = await pending?.value      // let an in-flight hypothesis decode finish first
                let peak = samples.max() ?? 0
                guard samples.count > 16_000 / 4 else {   // < 0.25 s of audio: nothing captured
                    log.error("Nothing captured: \(samples.count, privacy: .public) samples, peak \(peak, privacy: .public)")
                    await typer.retract(); await transcriber.beginLive(); state = .idle; return
                }
                guard peak > 1e-5 else {                    // digital silence: don't send it anywhere
                    log.error("Silent recording (\(samples.count / 16, privacy: .public) ms), input: \(AudioDevices.resolve(self.config.microphone)?.name ?? "?", privacy: .public)")
                    await typer.retract(); await transcriber.beginLive()
                    state = .error("Microphone gave silence: pick another input in Settings (built-in is off while the lid is closed)")
                    try? await Task.sleep(for: .seconds(5))
                    if case .error = state { state = .idle }
                    return
                }
                let t0 = Date()
                let raw = try await transcriber.liveFinish(samples)
                let t1 = Date()
                guard !raw.isEmpty else {
                    log.error("Empty transcript from \(samples.count / 16, privacy: .public) ms of audio, peak \(peak, privacy: .public)")
                    await typer.retract()
                    if peak < 1e-6 {
                        state = .error("Microphone gave silence: pick another input in Settings (built-in is off while the lid is closed)")
                        try? await Task.sleep(for: .seconds(5))
                        if case .error = state { state = .idle }
                    } else { state = .idle }
                    return
                }
                let prefix = fieldContext?.needsLeadingSpace == true ? " " : ""
                // The live text stays in the field while the model works; the polished text then replaces it in one
                // instant swap (typing it token by token looked like a re-transcription from the start).
                let polisher = config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : Polisher(config: config)
                var text = try await Pipeline.run(raw: raw, tone: tone, config: config, polisher: polisher,
                                                  examples: store.allCorrections(), context: fieldContext)
                let t2 = Date()
                log.info("Timing: audio \(Int(Double(samples.count) / 16), privacy: .public) ms, asr \(Int(t1.timeIntervalSince(t0) * 1000), privacy: .public) ms, polish \(Int(t2.timeIntervalSince(t1) * 1000), privacy: .public) ms, \(raw.split(separator: " ").count, privacy: .public) words")
                if !prefix.isEmpty, !text.hasPrefix("\n") { text = prefix + text }
                if typer.typed == text {
                    typer.forget()                        // nothing changed: leave the live text as it is
                } else if config.liveText, liveTextAllowed {
                    await typer.finish(with: text)        // one ordered sequence: backspaces, paste, clipboard back
                } else {
                    await typer.finish(with: text)        // nothing typed live: just the paste, then the clipboard back
                }
                var d = Dictation(date: Date(), text: text, raw: raw, app: targetBundleID, tone: tone,
                                  seconds: Double(samples.count) / 16_000)
                if config.keepClips {
                    d.clip = d.id.uuidString + ".wav"
                    do { try AudioRecorder.writeWav(samples, to: Store.clipsDirectory.appendingPathComponent(d.clip!)) }
                    catch { d.clip = nil; log.error("Clip not saved: \(error.localizedDescription, privacy: .public)") }
                }
                store.remember(d)
                rebuildHistoryMenu()
                log.info("[\(tone, privacy: .public)] \(raw, privacy: .public) -> \(text, privacy: .public)")
                state = .idle
            } catch {
                await typer.retract()
                log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                state = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(4))
                if case .error = state { state = .idle }
            }
        }
    }

    private func resolveTone() -> String {
        if let toneOverride { return toneOverride }
        let t = config.tones(for: targetBundleID)
        return useAlt ? t.alt : t.tone
    }

    // MARK: Settings window

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Yaptype"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            // `--settings <page>` opens straight to a page (used for screenshots/testing).
            let args = CommandLine.arguments
            let initial = args.firstIndex(of: "--settings").flatMap { i in args.indices.contains(i + 1) ? Page(rawValue: args[i + 1]) : nil } ?? .home
            w.contentView = NSHostingView(rootView: MainView(store: store, initial: initial))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        // Menu bar apps (accessory policy) often aren't granted activation on macOS 14+, which left the
        // window hidden behind whatever was frontmost. Order it front regardless, then activate.
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        if let w = settingsWindow, let screen = NSScreen.main {
            let r = w.frame   // logged as a top-left rect so `screencapture -R` can grab just this window
            log.info("settings window rect \(Int(r.minX)),\(Int(screen.frame.height - r.maxY)),\(Int(r.width)),\(Int(r.height))")
        }
    }

    // MARK: Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusLine = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toneMenu = NSMenu()
        let toneItem = NSMenuItem(title: "Tone", action: nil, keyEquivalent: "")
        toneItem.submenu = toneMenu
        menu.addItem(toneItem)

        historyMenu = NSMenu()
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Yaptype…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Yaptype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        rebuildToneMenu()
        rebuildHistoryMenu()
    }

    private func rebuildToneMenu() {
        toneMenu.removeAllItems()
        let auto = NSMenuItem(title: "Automatic (per app)", action: #selector(pickTone(_:)), keyEquivalent: "")
        auto.representedObject = nil
        auto.state = toneOverride == nil ? .on : .off
        toneMenu.addItem(auto)
        toneMenu.addItem(.separator())
        for name in config.tones.keys.sorted() {
            let item = NSMenuItem(title: name.capitalized, action: #selector(pickTone(_:)), keyEquivalent: "")
            item.representedObject = name
            item.state = toneOverride == name ? .on : .off
            toneMenu.addItem(item)
        }
    }

    /// Click an entry to copy it back to the clipboard.
    private func rebuildHistoryMenu() {
        historyMenu.removeAllItems()
        if store.history.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
            return
        }
        for (i, d) in store.history.prefix(15).enumerated() {
            let text = d.text
            let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            let title = oneLine.count > 70 ? String(oneLine.prefix(70)) + "…" : oneLine
            let item = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
            item.representedObject = text
            item.toolTip = text
            if i < 9 { item.keyEquivalent = String(i + 1); item.keyEquivalentModifierMask = [] }
            historyMenu.addItem(item)
        }
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLine.title = "Copied to clipboard"
    }

    @objc private func clearHistory() {
        store.clearHistory()
        rebuildHistoryMenu()
    }

    @objc private func pickTone(_ sender: NSMenuItem) {
        toneOverride = sender.representedObject as? String
        rebuildToneMenu()
    }

    private func render() {
        let symbol: String
        let text: String
        switch state {
        case .loading:    symbol = "hourglass";       text = "Loading models…"
        case .idle:
            symbol = "mic"
            if hotkey?.isRunning != true { text = "Grant Accessibility to enable the hotkey" }
            else if !store.polishReady { text = "Ready (rules only — add an OpenRouter key in Settings)" }
            else { text = "Ready — hold ⌘; to dictate" }
        case .recording:  symbol = "mic.fill";        text = toggleMode ? "Recording (tap ⌘; to stop, Esc to cancel)" : "Recording (release to finish)"
        case .processing: symbol = "ellipsis.circle"; text = "Transcribing…"
        case .error(let m): symbol = "exclamationmark.triangle"; text = "Error: \(m)"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        statusLine.title = text
        store.status = text
        guard config.overlay else { overlay.hide(); return }
        switch state {
        case .recording:    overlay.show(.listening)
        case .processing:   overlay.show(.processing)
        case .error(let m): overlay.show(.message(m))
        default: overlay.hide()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Tones can be added or removed in Settings, so refresh the submenus when the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildToneMenu()
        rebuildHistoryMenu()
    }
}
