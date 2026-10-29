import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

enum AudioDevices {
    static func inputs() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeInput) }

    static func outputs() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeOutput) }

    static func builtInInput() -> AudioDevice? { inputs().first(where: \.isBuiltIn) }

    static func builtInOutput() -> AudioDevice? { outputs().first(where: \.isBuiltIn) }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        allDeviceIDs()
            .filter { channelCount(of: $0, scope: scope) > 0 }
            .compactMap { id in
                guard let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                      let name = string(kAudioObjectPropertyName, of: id) else { return nil }
                let transport: UInt32 = value(kAudioDevicePropertyTransportType, of: id) ?? 0
                return AudioDevice(id: id, uid: uid, name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
            }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func channelCount(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    private static func value<T>(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> T? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
