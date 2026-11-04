import AppKit
import SwiftUI

/// The floating pill at the bottom of the screen: waveform while listening, dots while transcribing.
@MainActor
final class Overlay {
    enum Mode { case listening, processing, message(String) }

    private let panel: NSPanel
    private let model = OverlayModel()
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 52),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(_ mode: Mode) {
        hideTask?.cancel()
        model.mode = mode
        panel.ignoresMouseEvents = true
        panel.setContentSize(NSSize(width: 200, height: 52))
        if case .listening = mode { model.levels = Array(repeating: 0, count: OverlayModel.bars) }
        if case .listening = mode {} else { model.live = "" }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 28))
        }
        panel.orderFrontRegardless()
        if case .message = mode {
            hideTask = Task { try? await Task.sleep(for: .seconds(2.5)); if !Task.isCancelled { hide() } }
        }
    }

    func hide() { panel.orderOut(nil) }

    /// Microphone level 0...1, called from the audio thread.
    nonisolated func level(_ v: Float) {
        Task { @MainActor in self.model.push(v) }
    }

    /// Live transcript for the pill (apps where the field can't be read).
    func live(_ text: String) {
        model.live = text
        let wide = !text.isEmpty
        panel.setContentSize(NSSize(width: wide ? 520 : 200, height: wide ? 74 : 52))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 28))
        }
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    static let bars = 14
    @Published var mode: Overlay.Mode = .listening
    @Published var levels: [Float] = Array(repeating: 0, count: bars)
    /// Running transcript shown in the pill when live text can't go into the field.
    @Published var live = ""

    func push(_ v: Float) {
        levels.removeFirst()
        levels.append(min(1, v * 4))    // speech RMS sits around 0.05-0.2; scale so normal talking fills the bars
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @State private var phase = 0
    private var showsLive: Bool { if case .listening = model.mode { return !model.live.isEmpty }; return false }

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .listening:
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<OverlayModel.bars, id: \.self) { i in
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: 3, height: 4 + CGFloat(model.levels[i]) * 20)
                            .animation(.easeOut(duration: 0.08), value: model.levels[i])
                    }
                }
                .frame(height: 24)
                if !model.live.isEmpty {
                    Text(model.live).font(.system(size: 13)).foregroundStyle(Color(white: 0.92))
                        .lineLimit(2).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .processing:
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(Color.white).frame(width: 6, height: 6).opacity(phase == i ? 1 : 0.3)
                    }
                }
                Text("Transcribing").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            case .message(let text):
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(white: 0.1).opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .frame(width: showsLive ? 520 : 200, height: showsLive ? 74 : 52)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                phase = (phase + 1) % 3
            }
        }
    }
}

/// Soft start/stop cues using the system sounds so nothing needs bundling.
enum Cue {
    static func play(_ name: String) {
        guard let s = NSSound(named: name) else { return }
        s.volume = 0.25
        s.play()
    }
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
}
