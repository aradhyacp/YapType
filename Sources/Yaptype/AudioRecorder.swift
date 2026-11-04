import AVFoundation
import os

/// Captures a microphone and returns 16 kHz mono Float32 samples, which is what Parakeet expects.
/// Built on AVCaptureSession because it can record from a chosen device (built-in vs AirPods) reliably and
/// deliver 16 kHz mono directly; AVAudioEngine's device switching produced silence after a change.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var sessionDevice: String?
    private let queue = DispatchQueue(label: "com.yaptype.app.mic")
    private var samples: [Float] = []
    private var capturing = false
    private var observers: [NSObjectProtocol] = []
    private var secondSamples = 0
    private var secondPeak: Float = 0
    private var idleStop: DispatchWorkItem?
    private let lock = NSLock()
    /// After a recording the session keeps running this long (audio discarded) so the next hotkey press captures
    /// from the first word: AirPods and other Bluetooth mics deliver ~1 s of silence when they wake.
    var keepWarm: TimeInterval = 20
    private let log = Logger(subsystem: "com.yaptype.app", category: "audio")
    /// RMS level of each captured buffer (0...1), called on the capture queue.
    var onLevel: ((Float) -> Void)?
    /// Each 16 kHz mono chunk as it arrives (capture queue).
    var onChunkRaw: (([Float]) -> Void)?
    /// "" = system default, "builtin" = the Mac's own mic, or a device UID. See AudioDevices.
    var preferredDevice = ""

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func start() throws {
        let wanted = AudioDevices.resolve(preferredDevice)
        let device: AVCaptureDevice? = wanted.flatMap { w in
            AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
                .devices.first { $0.uniqueID == w.uid || $0.localizedName == w.name }
        } ?? AVCaptureDevice.default(for: .audio)
        guard let device else {
            throw NSError(domain: "Yaptype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone not available (is it connected and awake?)"])
        }
        // Keep the configured session between recordings (rebuilding makes AirPods re-open their mic, ~1-2 s of
        // silence); rebuild only when the chosen device changed.
        if session == nil || sessionDevice != device.uniqueID {
            if let old = session { DispatchQueue.global(qos: .userInitiated).async { old.stopRunning() } }
            let s = AVCaptureSession()
            s.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { throw NSError(domain: "Yaptype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't use \(device.localizedName)"]) }
            s.addInput(input)
            let out = AVCaptureAudioDataOutput()
            out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                 AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
            out.setSampleBufferDelegate(self, queue: queue)
            guard s.canAddOutput(out) else { throw NSError(domain: "Yaptype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't capture from \(device.localizedName)"]) }
            s.addOutput(out)
            s.commitConfiguration()
            session = s
            sessionDevice = device.uniqueID
            log.info("Microphone: \(device.localizedName, privacy: .public)")
            if observers.isEmpty {
                let nc = NotificationCenter.default
                for name in [AVCaptureDevice.wasDisconnectedNotification, AVCaptureDevice.wasConnectedNotification,
                             .AVCaptureSessionRuntimeError, .AVCaptureSessionWasInterrupted, .AVCaptureSessionInterruptionEnded,
                             .AVCaptureSessionDidStopRunning] {
                    observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
                        let detail = (n.object as? AVCaptureDevice)?.localizedName ?? (n.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? ""
                        self?.log.error("Capture event: \(name.rawValue, privacy: .public) \(detail, privacy: .public)")
                        if name == AVCaptureDevice.wasDisconnectedNotification, (n.object as? AVCaptureDevice)?.uniqueID == self?.sessionDevice {
                            self?.sessionDevice = nil          // rebuild on the next start with whatever is available
                        }
                    })
                }
            }
        }
        idleStop?.cancel(); idleStop = nil
        lock.lock(); samples.removeAll(keepingCapacity: true); capturing = true; lock.unlock()
        // startRunning blocks for up to a second on a cold Bluetooth mic. On the main thread that delayed the
        // hotkey's key-up, which made a quick tap look like a long press and ended the dictation at once.
        if let s = session, !s.isRunning { queue.async { s.startRunning() } }
    }

    /// True while the capture session is running (recording or kept warm after a recording).
    var isRunning: Bool { session?.isRunning == true }

    /// Everything recorded so far, without stopping.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Stops capture and returns everything recorded since start().
    func stop() -> [Float] {
        lock.lock()
        capturing = false
        let out = samples
        samples = []
        lock.unlock()
        let stopLater = DispatchWorkItem { [weak self] in
            let s = self?.session
            DispatchQueue.global(qos: .utility).async { s?.stopRunning() }
        }
        idleStop = stopLater
        DispatchQueue.main.asyncAfter(deadline: .now() + keepWarm, execute: stopLater)
        return out
    }

    /// Stop the session right away (cancel, device change). stopRunning can block for seconds on Bluetooth
    /// inputs, so it runs off the main thread.
    func shutdown() {
        idleStop?.cancel()
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s?.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr, let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let chunk = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        guard !chunk.isEmpty else { return }
        lock.lock()
        let active = capturing
        if active { samples.append(contentsOf: chunk) }
        secondSamples += chunk.count
        secondPeak = max(secondPeak, chunk.map { abs($0) }.max() ?? 0)
        if secondSamples >= 16_000 {
            log.info("mic: \(self.secondSamples, privacy: .public) samples, peak \(self.secondPeak, privacy: .public), capturing \(active, privacy: .public)")
            secondSamples = 0; secondPeak = 0
        }
        lock.unlock()
        guard active else { return }
        onChunkRaw?(chunk)
        onLevel?(sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)))
    }

    // MARK: Clips (16 kHz mono WAV, the exact samples the transcriber saw)

    static func writeWav(_ samples: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: targetFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    }

    static func readWav(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}
