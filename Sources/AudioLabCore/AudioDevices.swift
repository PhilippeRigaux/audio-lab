import CoreAudio
import Foundation

public struct AudioDevice {
    public let id: AudioDeviceID
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool

    public init(id: AudioDeviceID, name: String, hasInput: Bool, hasOutput: Bool) {
        self.id = id
        self.name = name
        self.hasInput = hasInput
        self.hasOutput = hasOutput
    }
}

public enum AudioDeviceManager {
    public static func listDevices() throws -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else {
            throw AppError.message("Could not query audio devices (code \(status))")
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: deviceCount)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &ids)
        guard status == noErr else {
            throw AppError.message("Could not fetch audio devices (code \(status))")
        }

        return ids.compactMap { id in
            guard let name = try? deviceName(id: id) else { return nil }
            let hasInput = (try? supportsStreams(id: id, scope: kAudioDevicePropertyScopeInput)) ?? false
            let hasOutput = (try? supportsStreams(id: id, scope: kAudioDevicePropertyScopeOutput)) ?? false
            return AudioDevice(id: id, name: name, hasInput: hasInput, hasOutput: hasOutput)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func findDeviceID(matching query: String, requiresInput: Bool) throws -> AudioDeviceID {
        let devices = try listDevices().filter { requiresInput ? $0.hasInput : $0.hasOutput }

        if let asID = UInt32(query), devices.contains(where: { $0.id == asID }) {
            return asID
        }

        if let exact = devices.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return exact.id
        }

        let partialMatches = devices.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if partialMatches.count == 1, let match = partialMatches.first {
            return match.id
        }

        if partialMatches.count > 1 {
            let candidates = partialMatches.map { "\($0.id): \($0.name)" }.joined(separator: ", ")
            throw AppError.message("Ambiguous device '\(query)'. Matches: \(candidates)")
        }

        throw AppError.message("No matching \(requiresInput ? "input" : "output") device for '\(query)'")
    }

    public static func nominalSampleRate(id: AudioDeviceID) throws -> Double {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Double = 0
        var dataSize = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, &sampleRate)
        guard status == noErr else {
            throw AppError.message("Could not read sample rate for device id \(id) (code \(status))")
        }

        return sampleRate
    }

    public static func setNominalSampleRate(id: AudioDeviceID, sampleRate: Double) throws {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableRate = sampleRate
        let dataSize = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectSetPropertyData(id, &propertyAddress, 0, nil, dataSize, &mutableRate)
        guard status == noErr else {
            throw AppError.message("Could not set sample rate \(sampleRate) on device id \(id) (code \(status))")
        }
    }

    public static func defaultInputDeviceID() throws -> AudioDeviceID {
        try defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutputDeviceID() throws -> AudioDeviceID {
        try defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else {
            throw AppError.message("Could not query channel count for id \(id) (code \(status))")
        }
        if dataSize == 0 { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let status2 = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, rawPointer)
        guard status2 == noErr else {
            throw AppError.message("Could not read channel count for id \(id) (code \(status2))")
        }

        let list = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func bufferFrameSize(id: AudioDeviceID) throws -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var frameSize: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, &frameSize)
        guard status == noErr else {
            throw AppError.message("Could not read buffer frame size for id \(id) (code \(status))")
        }

        return frameSize
    }

    @discardableResult
    public static func setBufferFrameSize(id: AudioDeviceID, frames: UInt32) throws -> UInt32 {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        let rangeStatus = AudioObjectGetPropertyData(id, &rangeAddress, 0, nil, &rangeSize, &range)
        guard rangeStatus == noErr else {
            throw AppError.message("Could not read buffer frame size range for id \(id) (code \(rangeStatus))")
        }

        let clamped = min(max(Double(frames), range.mMinimum), range.mMaximum)
        var target = UInt32(clamped.rounded())

        var sizeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let size = UInt32(MemoryLayout<UInt32>.size)
        let setStatus = AudioObjectSetPropertyData(id, &sizeAddress, 0, nil, size, &target)
        guard setStatus == noErr else {
            throw AppError.message("Could not set buffer frame size \(target) for id \(id) (code \(setStatus))")
        }

        return try bufferFrameSize(id: id)
    }

    private static func deviceName(id: AudioDeviceID) throws -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 256
        var chars = [CChar](repeating: 0, count: Int(dataSize))
        let status = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, &chars)
        guard status == noErr else {
            throw AppError.message("Could not read device name for id \(id) (code \(status))")
        }

        let endIndex = chars.firstIndex(of: 0) ?? chars.endIndex
        let bytes = chars[..<endIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func supportsStreams(id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else {
            throw AppError.message("Could not query device stream support for id \(id) (code \(status))")
        }

        if dataSize == 0 { return false }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let status2 = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, rawPointer)
        guard status2 == noErr else {
            throw AppError.message("Could not read device stream configuration for id \(id) (code \(status2))")
        }

        let bufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let totalChannels = audioBuffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return totalChannels > 0
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &propertyAddress,
                                                0,
                                                nil,
                                                &dataSize,
                                                &deviceID)
        guard status == noErr, deviceID != 0 else {
            throw AppError.message("Could not read default device (selector \(selector), code \(status))")
        }
        return deviceID
    }
}
