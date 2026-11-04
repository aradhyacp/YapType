import AppKit
import AVFoundation

/// `Yaptype --livetest clip.wav`: pushes a 16 kHz WAV through the streaming path in real time, typing live text
/// into TextEdit exactly like a dictation would, then retracts it and pastes the final text. Types only while
/// TextEdit is frontmost so a stray click elsewhere can't receive text.
enum LiveTest {
    @MainActor static func run(_ path: String) async -> Bool {
        let target = CommandLine.arguments.firstIndex(of: "--target").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "com.apple.TextEdit"
        func frontIsTarget() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target }
        guard let config = try? Config.load(), let samples = try? AudioRecorder.readWav(URL(fileURLWithPath: path)) else {
            print("livetest: bad config or wav"); return false
        }
        let transcriber = Transcriber()
        do {
            try await transcriber.load(version: config.asrVersion)
            await transcriber.setVocabulary(config.dictionary)
        } catch { print("livetest: \(error.localizedDescription)"); return false }
        guard frontIsTarget() else { print("livetest: \(target) is not frontmost, aborting"); return false }
        let typer = LiveTyper()
        let context = FieldContext.capture()
        typer.begin(context: context)
        let prefix = context.needsLeadingSpace ? " " : ""
        print("field before cursor: \(context.before.count) chars, leading space: \(context.needsLeadingSpace)")
        await transcriber.beginLive()
        var updates = 0, fed = 0
        let t0 = Date()
        while fed < samples.count {
            fed = min(fed + 8000, samples.count)              // 500 ms of "speech" arrives
            try? await Task.sleep(for: .milliseconds(350))
            if let text = try? await transcriber.liveUpdate(Array(samples[..<fed])) {
                updates += 1
                if frontIsTarget() { await typer.update(prefix + text) }
                print("  live \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(text)")
            }
        }
        let released = Date()
        let raw = (try? await transcriber.liveFinish(samples)) ?? ""
        let t1 = Date()
        let maybePolisher = Polisher(config: config)
        let usePolish = maybePolisher.isConfigured
        let text = (try? await Pipeline.run(raw: raw, tone: "professional", config: config,
                                            polisher: usePolish ? maybePolisher : nil, examples: [:], context: context)) ?? raw
        let t2 = Date()
        guard frontIsTarget() else { print("livetest: \(target) lost focus before the swap; not touching the field"); return false }
        await typer.finish(with: prefix + text)
        try? await Task.sleep(for: .milliseconds(300))
        print("raw:   \(raw)\nfinal: \(text)\nupdates: \(updates), typed while speaking: \(Int(released.timeIntervalSince(t0)))s, finish after release: \(Int(t1.timeIntervalSince(released) * 1000)) ms, polish: \(Int(t2.timeIntervalSince(t1) * 1000)) ms (openrouter \(usePolish))")
        return !raw.isEmpty
    }
}
