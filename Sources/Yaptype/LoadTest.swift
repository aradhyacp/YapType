import CoreML
import FluidAudio
import Foundation

/// `Yaptype --loadtest [--allcpu] [--compute=cpuAndGPU|cpuAndNeuralEngine|cpuOnly|all] [--wav=clip.wav]`: loads the
/// cached Parakeet models, optionally transcribes a clip twice, and prints how long each phase took. Used to compare
/// startup paths; never downloads unless the cache is missing.
enum LoadTest {
    /// `Yaptype --prewarm`: load the cached speech model once and exit. The install script runs this after copying
    /// the app: CoreML keys part of its compile cache to the signed binary, so a fresh build would otherwise spend a
    /// few seconds preparing the model on the first launch.
    static func prewarm() async -> Bool {
        guard let config = try? Config.load() else { return false }
        let version: AsrModelVersion = config.asrVersion == "v3" ? .v3 : .v2
        let directory = AsrModels.defaultCacheDirectory(for: version)
        guard AsrModels.modelsExist(at: directory, version: version) else { return true }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        do {
            let models = try await AsrModels.loadFromCache(
                configuration: configuration, version: version, encoderComputeUnits: .cpuOnly)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return true
        } catch {
            return false
        }
    }

    static func run() async -> Bool {
        let name = CommandLine.arguments.first { $0.hasPrefix("--compute=") }
            .map { String($0.dropFirst("--compute=".count)) } ?? "cpuOnly"
        let units: MLComputeUnits
        switch name {
        case "cpuOnly": units = .cpuOnly
        case "cpuAndGPU": units = .cpuAndGPU
        case "all": units = .all
        default: units = .cpuAndNeuralEngine
        }
        let version: AsrModelVersion = CommandLine.arguments.contains("--v3") ? .v3 : .v2
        let directory = AsrModels.defaultCacheDirectory(for: version)
        let exists = AsrModels.modelsExist(at: directory, version: version)
        let allCPU = CommandLine.arguments.contains("--allcpu")
        var configuration: MLModelConfiguration?
        if allCPU {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            configuration = config
        }
        print("cache: \(directory.path)")
        print("cached: \(exists), encoder: \(name), all: \(allCPU ? "cpuOnly" : "default")")

        let started = Date()
        do {
            let models: AsrModels
            if exists {
                models = try await AsrModels.load(
                    from: directory, configuration: configuration, version: version,
                    encoderComputeUnits: allCPU ? .cpuOnly : units)
            } else {
                models = try await AsrModels.downloadAndLoad(
                    configuration: configuration, version: version,
                    encoderComputeUnits: allCPU ? .cpuOnly : units)
            }
            let loaded = Date()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let ready = Date()
            print(String(
                format: "models: %.2fs, manager: %.2fs, total: %.2fs",
                loaded.timeIntervalSince(started),
                ready.timeIntervalSince(loaded),
                ready.timeIntervalSince(started)))

            if let wav = CommandLine.arguments.first(where: { $0.hasPrefix("--wav=") })
                .map({ String($0.dropFirst("--wav=".count)) }) {
                let samples = try AudioRecorder.readWav(URL(fileURLWithPath: wav))
                for round in 1...2 {
                    var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
                    let t0 = Date()
                    let result = try await manager.transcribe(samples, decoderState: &state)
                    let ms = Date().timeIntervalSince(t0) * 1000
                    print(String(format: "transcribe %d: %.0f ms (%.1fs audio) %@",
                                 round, ms, Double(samples.count) / 16_000, result.text))
                }
            }
            return true
        } catch {
            print("loadtest failed: \(error.localizedDescription)")
            return false
        }
    }
}
