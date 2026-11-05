import AppKit
import AVFoundation

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}
if CommandLine.arguments.contains("--dumpconfig") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(Config()), let text = String(data: data, encoding: .utf8) { print(text) }
    exit(0)
}
if CommandLine.arguments.contains("--context") {
    // Debug: what the Accessibility reader sees for the frontmost app right now (sizes only, no field text).
    let c = FieldContext.capture()
    print("trusted: \(AXIsProcessTrusted()) debug: \(FieldContext.debug())")
    print("window title: \(c.windowTitle)\nbefore cursor: \(c.before.count) chars\nafter cursor: \(c.after.count) chars\nneeds leading space: \(c.needsLeadingSpace)")
    exit(0)
}
if CommandLine.arguments.contains("--prewarm") {
    Task { exit(await LoadTest.prewarm() ? 0 : 1) }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--loadtest") {
    Task { exit(await LoadTest.run() ? 0 : 1) }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--livetest"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    Task { @MainActor in exit(await LiveTest.run(path) ? 0 : 1) }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--polishtest"), i + 1 < CommandLine.arguments.count {
    let raw = CommandLine.arguments[i + 1]
    Task { exit(await PolishTest.run(raw) ? 0 : 1) }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--dumpprompt"), i + 1 < CommandLine.arguments.count, let config = try? Config.load() {
    let tone = CommandLine.arguments[i + 1]
    let po = Polisher(config: config)
    print(po.systemPrompt(tones: config.tones, dictionary: config.dictionary, memory: config.memory, examples: [:]))
    print("=====USER=====\n" + po.userMessage("TRANSCRIPT", tone: tone, context: nil))
    exit(0)
}
if CommandLine.arguments.contains("--enginetest") {
    // Same microphone through AVAudioEngine (default input), to compare with the AVCaptureSession path.

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let fmt = input.inputFormat(forBus: 0)
    print("engine input format: \(fmt)")
    var peaks: [Float] = []
    var count = 0
    var peak: Float = 0
    let lock = NSLock()
    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        let p = (0..<n).reduce(Float(0)) { max($0, abs(ch[0][$1])) }
        lock.lock(); count += n; peak = max(peak, p); lock.unlock()
    }
    engine.prepare()
    do { try engine.start() } catch { print("engine start failed: \(error)"); exit(1) }
    Task {
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            lock.lock(); peaks.append(peak); peak = 0; lock.unlock()
        }
        engine.stop()
        print("engine: \(count) frames, per-second peak: " + peaks.map { String(format: "%.3f", $0) }.joined(separator: " "))
        exit(0)
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--mictest") {
    // Records 3 s twice in a row and reports what the microphone delivered (sample count, peak, time to first buffer).
    Task {
        let r = AudioRecorder()
        print("inputs:", AudioDevices.inputs().map { "\($0.name)\($0.isBuiltIn ? " (built-in)" : "")" }.joined(separator: ", "))
        r.preferredDevice = CommandLine.arguments.contains("--default") ? "" : "builtin"
        let seconds = Int(CommandLine.arguments.first { $0.hasPrefix("--seconds=") }?.dropFirst(10) ?? "3") ?? 3
        let gap = Int(CommandLine.arguments.first { $0.hasPrefix("--gap=") }?.dropFirst(6) ?? "0") ?? 0
        for round in 1...2 {
            var first: Date?
            r.onLevel = { _ in if first == nil { first = Date() } }
            let t0 = Date()
            do { try r.start() } catch { print("round \(round): start failed: \(error.localizedDescription)"); continue }
            print("round \(round): started")
            var timeline: [String] = []
            for _ in 0..<seconds {
                try? await Task.sleep(for: .seconds(1))
                let snap = r.snapshot()
                let last = snap.suffix(16_000)
                timeline.append(String(format: "%.3f", last.map { abs($0) }.max() ?? 0))
            }
            let s = r.stop()
            print("round \(round): \(s.count) samples (\(s.count / 16) ms), peak \(s.map { abs($0) }.max() ?? 0), first buffer after \(first.map { Int($0.timeIntervalSince(t0) * 1000) } ?? -1) ms")
            print("   per-second peak: \(timeline.joined(separator: " "))")
            if round == 1, gap > 0 { print("   waiting \(gap) s (session idles out after 20 s)"); try? await Task.sleep(for: .seconds(gap)) }
        }
        exit(0)
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--eval") {
    Task { exit(await Eval.run() ? 0 : 1) }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
