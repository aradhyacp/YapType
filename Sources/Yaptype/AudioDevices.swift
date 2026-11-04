import CoreAudio
import Foundation
import IOKit

/// Input devices on this Mac, so the user can pick the built-in mic over AirPods (which take ~2 s to wake their
/// narrowband mic every time they've been idle).
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    /// iPhone/iPad Continuity microphones: never picked automatically.
    let isContinuity: Bool
}

enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid: String = string(id, kAudioDevicePropertyDeviceUID),
                  let name: String = string(id, kAudioObjectPropertyName) else { return nil }
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport)
            // Aggregate and virtual devices (loopback drivers, screen-capture taps) are not microphones.
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual || name.hasPrefix("Yaptype") { return nil }
            let continuity = transport == kAudioDeviceTransportTypeContinuityCaptureWired || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
                || name.localizedCaseInsensitiveContains("iphone") || name.localizedCaseInsensitiveContains("ipad")
            return AudioInputDevice(id: id, uid: uid, name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn, isContinuity: continuity)
        }
    }

    /// Resolves the config value: "" = system default, "builtin" = built-in mic if present, otherwise a device UID.
    /// The system default is read from Core Audio (AVCaptureDevice's notion lags behind when AirPods come and go),
    /// and a built-in mic is skipped while the lid is closed, since macOS mutes it then.
    static func resolve(_ preference: String) -> AudioInputDevice? {
        let all = inputs()
        if preference == "builtin" { return all.first { $0.isBuiltIn } }
        if !preference.isEmpty { return all.first { $0.uid == preference } }
        var chosen = all.first { $0.id == defaultInputID() } ?? all.first
        if chosen?.isBuiltIn == true, lidClosed(), let other = all.first(where: { !$0.isBuiltIn && !$0.isContinuity }) { chosen = other }
        return chosen
    }

    static func defaultInputID() -> AudioDeviceID {
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return false }
        return (v as? Bool) ?? false
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
