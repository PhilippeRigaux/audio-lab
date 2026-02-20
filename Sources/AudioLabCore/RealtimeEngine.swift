import AVFoundation
import AppKit
import AudioUnit
import AudioToolbox
import CoreAudioKit
import CoreAudio
import Foundation

@objc private protocol AUCocoaViewFactory {
    @objc(uiViewForAudioUnit:withSize:)
    func uiView(forAudioUnit audioUnit: AudioUnit, with size: NSSize) -> NSView?
}

public struct AudioMeters {
    public let inputPeakDBFS: Double
    public let outputPeakDBFS: Double
    public let outputIntegratedLUFS: Double
}

public final class RealtimeEngine {
    public typealias PluginState = [String: Any]
    private struct HostedPlugin {
        var avAudioUnit: AVAudioUnit
        var audioUnit: AudioUnit
        var bypassed: Bool
        var nonInterleavedIO: Bool
    }

    private let inputDeviceName: String?
    private let outputDeviceName: String?
    private let pluginComponentDescriptions: [AudioComponentDescription]

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?

    private var sampleRate: Double = 48_000
    fileprivate var channels: UInt32 = 2
    private var maxFramesPerSlice: UInt32 = 2048

    private var ringBuffer: FloatRingBuffer?
    private var hostedPlugins: [HostedPlugin] = []
    private let dspLock = NSLock()
    private let meterLock = NSLock()
    private var inputMeterLinear: Float = 0
    private var outputMeterLinear: Float = 0
    private var outputLufsDB: Double = -120
    private var outputIntegratedEnergy: Double = 0
    private var outputIntegratedSamples: UInt64 = 0

    private var inputScratch: [Float] = []
    private var outputScratch: [Float] = []
    private var pluginInputScratch: [Float] = []
    private var pluginOutputScratch: [Float] = []
    private var lastOutputFrame: [Float] = [0, 0]
    private var targetBufferFrames: Int = 0
    private var lowWaterBufferFrames: Int = 0
    private var highWaterBufferFrames: Int = 0
    fileprivate var pluginFeedPointer: UnsafeMutablePointer<Float>?
    fileprivate var pluginFeedFrames: Int = 0

    public init(inputDeviceName: String?,
                outputDeviceName: String?,
                pluginComponentDescriptions: [AudioComponentDescription]) {
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.pluginComponentDescriptions = pluginComponentDescriptions
    }

    public convenience init(inputDeviceName: String?,
                            outputDeviceName: String?,
                            pluginComponentDescription: AudioComponentDescription? = nil) {
        self.init(inputDeviceName: inputDeviceName,
                  outputDeviceName: outputDeviceName,
                  pluginComponentDescriptions: pluginComponentDescription.map { [$0] } ?? [])
    }

    public func start() throws {
        let inputID = try resolveInputDeviceID()
        let outputID = try resolveOutputDeviceID()

        if !pluginComponentDescriptions.isEmpty {
            _ = try? AudioDeviceManager.setBufferFrameSize(id: inputID, frames: 512)
            _ = try? AudioDeviceManager.setBufferFrameSize(id: outputID, frames: 512)
        }

        sampleRate = try AudioDeviceManager.nominalSampleRate(id: inputID)
        let outputRate = try AudioDeviceManager.nominalSampleRate(id: outputID)
        if abs(sampleRate - outputRate) > 0.1 {
            try AudioDeviceManager.setNominalSampleRate(id: outputID, sampleRate: sampleRate)
        }

        let inputChannels = try max(1, AudioDeviceManager.channelCount(id: inputID, scope: kAudioDevicePropertyScopeInput))
        let outputChannels = try max(1, AudioDeviceManager.channelCount(id: outputID, scope: kAudioDevicePropertyScopeOutput))
        channels = UInt32(min(min(inputChannels, outputChannels), 2))

        let inputAU = try makeHALAudioUnit()
        let outputAU = try makeHALAudioUnit()

        try configureInputUnit(inputAU, deviceID: inputID)
        try configureOutputUnit(outputAU, deviceID: outputID)
        let maxInputFrames = try maxFrames(for: inputAU)
        let maxOutputFrames = try maxFrames(for: outputAU)
        maxFramesPerSlice = max(max(maxInputFrames, maxOutputFrames), 512)
        try configurePluginUnitsIfNeeded()

        let frameCapacity = Int(maxFramesPerSlice) * 24
        ringBuffer = FloatRingBuffer(capacityFrames: frameCapacity, channels: Int(channels))
        inputScratch = Array(repeating: 0, count: Int(maxFramesPerSlice * channels))
        outputScratch = Array(repeating: 0, count: Int(maxFramesPerSlice * channels))
        pluginInputScratch = Array(repeating: 0, count: Int(maxFramesPerSlice * channels))
        pluginOutputScratch = Array(repeating: 0, count: Int(maxFramesPerSlice * channels))
        lastOutputFrame = Array(repeating: 0, count: Int(channels))
        targetBufferFrames = Int(maxFramesPerSlice) * 5
        lowWaterBufferFrames = Int(maxFramesPerSlice) * 3
        highWaterBufferFrames = Int(maxFramesPerSlice) * 8

        try setMaxFrames(maxFramesPerSlice, for: inputAU)
        try setMaxFrames(maxFramesPerSlice, for: outputAU)
        for plugin in hostedPlugins {
            setMaxFramesBestEffort(maxFramesPerSlice, for: plugin.audioUnit, context: "plugin")
        }

        try initialize(audioUnit: inputAU)
        try initialize(audioUnit: outputAU)

        try start(audioUnit: inputAU)
        try prefillBufferForStableStart()
        try start(audioUnit: outputAU)

        meterLock.lock()
        inputMeterLinear = 0
        outputMeterLinear = 0
        outputLufsDB = -120
        outputIntegratedEnergy = 0
        outputIntegratedSamples = 0
        meterLock.unlock()
        lastOutputFrame = Array(repeating: 0, count: Int(channels))

        inputUnit = inputAU
        outputUnit = outputAU

        print("Dual-HAL running at \(Int(sampleRate)) Hz, \(channels) ch")
    }

    deinit {
        stop()
    }

    public func stop() {
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
            self.inputUnit = nil
        }

        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }
        dspLock.lock()
        pluginFeedPointer = nil
        pluginFeedFrames = 0
        dspLock.unlock()
        teardownPluginUnitsOnMainThread()
        meterLock.lock()
        inputMeterLinear = 0
        outputMeterLinear = 0
        outputLufsDB = -120
        outputIntegratedEnergy = 0
        outputIntegratedSamples = 0
        meterLock.unlock()
        lastOutputFrame = Array(repeating: 0, count: Int(channels))
    }

    private func teardownPluginUnitsOnMainThread() {
        let teardown = { [self] in
            for plugin in hostedPlugins {
                AudioUnitUninitialize(plugin.audioUnit)
            }
            hostedPlugins.removeAll()
        }

        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }

    public func setPluginBypassed(_ bypassed: Bool) {
        dspLock.lock()
        for index in hostedPlugins.indices {
            hostedPlugins[index].bypassed = bypassed
        }
        dspLock.unlock()
    }

    public func setPluginBypassed(index: Int, bypassed: Bool) {
        dspLock.lock()
        if hostedPlugins.indices.contains(index) {
            hostedPlugins[index].bypassed = bypassed
        }
        dspLock.unlock()
    }

    public func capturePluginStates() -> [PluginState?] {
        dspLock.lock()
        let audioUnits = hostedPlugins.map { $0.avAudioUnit.auAudioUnit }
        dspLock.unlock()
        return audioUnits.map { $0.fullState }
    }

    public func applyPluginStates(_ states: [PluginState?]) {
        dspLock.lock()
        let audioUnits = hostedPlugins.map { $0.avAudioUnit.auAudioUnit }
        dspLock.unlock()

        guard !audioUnits.isEmpty else { return }
        for (index, audioUnit) in audioUnits.enumerated() {
            guard states.indices.contains(index), let state = states[index] else { continue }
            audioUnit.fullState = state
        }
    }

    public func currentMeters() -> AudioMeters {
        meterLock.lock()
        let inputLinear = inputMeterLinear
        let outputLinear = outputMeterLinear
        let outputLufs = outputLufsDB
        meterLock.unlock()

        return AudioMeters(
            inputPeakDBFS: Self.dbFS(fromLinear: inputLinear),
            outputPeakDBFS: Self.dbFS(fromLinear: outputLinear),
            outputIntegratedLUFS: outputLufs
        )
    }

    public func hostedPluginAUAudioUnit(index: Int) -> AUAudioUnit? {
        dspLock.lock()
        defer { dspLock.unlock() }
        guard hostedPlugins.indices.contains(index) else { return nil }
        return hostedPlugins[index].avAudioUnit.auAudioUnit
    }

    @MainActor
    public func requestPluginEditorViewController(index: Int, completion: @escaping (NSViewController?) -> Void) {
        guard let auAudioUnit = hostedPluginAUAudioUnit(index: index) else {
            completion(nil)
            return
        }
        guard let avAudioUnit = hostedAVAudioUnit(index: index) else {
            completion(nil)
            return
        }

        auAudioUnit.requestViewController { [weak self] viewController in
            Task { @MainActor in
                guard let self else {
                    completion(viewController)
                    return
                }
                completion(viewController ?? self.makeLegacyPluginEditorViewController(audioUnit: avAudioUnit.audioUnit))
            }
        }
    }

    @MainActor
    private func makeLegacyPluginEditorViewController(audioUnit: AudioUnit) -> NSViewController? {
        let controller = NSViewController()
        if let cocoaView = makeCocoaPluginView(audioUnit: audioUnit) {
            controller.view = cocoaView
            let fitted = cocoaView.fittingSize
            if fitted.width > 0, fitted.height > 0 {
                controller.preferredContentSize = fitted
            }
            return controller
        }

        // Fallback: generic AU parameter UI when plugin-specific view is unavailable.
        let genericView = AUGenericView(audioUnit: audioUnit)
        let fitted = genericView.fittingSize
        let fallback = NSSize(width: max(640, fitted.width), height: max(420, fitted.height))
        genericView.frame = NSRect(origin: .zero, size: fallback)
        controller.view = genericView
        controller.preferredContentSize = fallback
        return controller
    }

    @MainActor
    private func makeCocoaPluginView(audioUnit: AudioUnit) -> NSView? {
        var dataSize: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = AudioUnitGetPropertyInfo(audioUnit,
                                                  kAudioUnitProperty_CocoaUI,
                                                  kAudioUnitScope_Global,
                                                  0,
                                                  &dataSize,
                                                  &writable)
        guard infoStatus == noErr, dataSize >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else {
            return nil
        }

        let cocoaInfo = UnsafeMutablePointer<AudioUnitCocoaViewInfo>.allocate(capacity: 1)
        defer { cocoaInfo.deallocate() }

        var cocoaInfoSize = UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size)
        let status = AudioUnitGetProperty(audioUnit,
                                          kAudioUnitProperty_CocoaUI,
                                          kAudioUnitScope_Global,
                                          0,
                                          cocoaInfo,
                                          &cocoaInfoSize)
        guard status == noErr else { return nil }

        let bundleURL = cocoaInfo.pointee.mCocoaAUViewBundleLocation.takeUnretainedValue() as URL
        let viewClassName = cocoaInfo.pointee.mCocoaAUViewClass.takeUnretainedValue() as String
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        bundle.load()

        guard let cocoaViewClass = bundle.classNamed(viewClassName) as? NSObject.Type else { return nil }
        let factoryObject = cocoaViewClass.init()
        guard let cocoaFactory = factoryObject as? AUCocoaViewFactory else { return nil }
        // Some legacy AUv2 views mis-handle popup/menu hit-testing when initialized with a zero size.
        let requestedSize = NSSize(width: 1024, height: 720)
        return cocoaFactory.uiView(forAudioUnit: audioUnit, with: requestedSize)
    }

    private func hostedAVAudioUnit(index: Int) -> AVAudioUnit? {
        dspLock.lock()
        defer { dspLock.unlock() }
        guard hostedPlugins.indices.contains(index) else { return nil }
        return hostedPlugins[index].avAudioUnit
    }

    private func resolveInputDeviceID() throws -> AudioDeviceID {
        if let name = inputDeviceName {
            return try AudioDeviceManager.findDeviceID(matching: name, requiresInput: true)
        }
        return try AudioDeviceManager.defaultInputDeviceID()
    }

    private func resolveOutputDeviceID() throws -> AudioDeviceID {
        if let name = outputDeviceName {
            return try AudioDeviceManager.findDeviceID(matching: name, requiresInput: false)
        }
        return try AudioDeviceManager.defaultOutputDeviceID()
    }

    private func makeHALAudioUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AppError.message("Could not find HALOutput audio component")
        }

        var audioUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit else {
            throw AppError.message("Could not create HAL audio unit (code \(status))")
        }

        return audioUnit
    }

    private func configureInputUnit(_ audioUnit: AudioUnit, deviceID: AudioDeviceID) throws {
        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        var mutableDeviceID = deviceID

        try setProperty(audioUnit, selector: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, data: &enableIO)
        try setProperty(audioUnit, selector: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, data: &disableIO)
        try setProperty(audioUnit, selector: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, data: &mutableDeviceID)

        var format = streamFormat(sampleRate: sampleRate, channels: channels)
        try setProperty(audioUnit, selector: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: 1, data: &format)

        var callback = AURenderCallbackStruct(
            inputProc: inputRenderProc,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        try setProperty(audioUnit, selector: kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, element: 0, data: &callback)
    }

    private func configureOutputUnit(_ audioUnit: AudioUnit, deviceID: AudioDeviceID) throws {
        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        var mutableDeviceID = deviceID

        try setProperty(audioUnit, selector: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, data: &enableIO)
        try setProperty(audioUnit, selector: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, data: &disableIO)
        try setProperty(audioUnit, selector: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, data: &mutableDeviceID)

        var format = streamFormat(sampleRate: sampleRate, channels: channels)
        try setProperty(audioUnit, selector: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, element: 0, data: &format)

        var callback = AURenderCallbackStruct(
            inputProc: outputRenderProc,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        try setProperty(audioUnit, selector: kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Global, element: 0, data: &callback)
    }

    private func configurePluginUnitsIfNeeded() throws {
        guard !pluginComponentDescriptions.isEmpty else {
            hostedPlugins.removeAll()
            return
        }

        hostedPlugins.removeAll(keepingCapacity: true)
        for description in pluginComponentDescriptions {
            let avUnit = try instantiatePluginSynchronously(description: description)
            let audioUnit = avUnit.audioUnit
            let nonInterleavedIO = try configurePluginStreamFormat(audioUnit)

            var callback = AURenderCallbackStruct(
                inputProc: pluginInputRenderProc,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            try setPluginRenderCallback(audioUnit, callback: &callback)

            setMaxFramesBestEffort(maxFramesPerSlice, for: audioUnit, context: "plugin")
            try initialize(audioUnit: audioUnit)

            hostedPlugins.append(HostedPlugin(
                avAudioUnit: avUnit,
                audioUnit: audioUnit,
                bypassed: false,
                nonInterleavedIO: nonInterleavedIO
            ))
        }
    }

    private func configurePluginStreamFormat(_ audioUnit: AudioUnit) throws -> Bool {
        let attempts: [Bool] = [true, false]
        var lastStatus: OSStatus = -1

        for useNonInterleaved in attempts {
            var format = streamFormat(sampleRate: sampleRate, channels: channels, interleaved: !useNonInterleaved)
            let inputStatus = setPropertyStatus(audioUnit,
                                                selector: kAudioUnitProperty_StreamFormat,
                                                scope: kAudioUnitScope_Input,
                                                element: 0,
                                                data: &format)
            let outputStatus = setPropertyStatus(audioUnit,
                                                 selector: kAudioUnitProperty_StreamFormat,
                                                 scope: kAudioUnitScope_Output,
                                                 element: 0,
                                                 data: &format)

            if inputStatus == noErr, outputStatus == noErr {
                return useNonInterleaved
            }

            lastStatus = inputStatus != noErr ? inputStatus : outputStatus
        }

        throw AppError.message("Plugin stream format setup failed (code \(lastStatus))")
    }

    private func instantiatePluginSynchronously(description: AudioComponentDescription) throws -> AVAudioUnit {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedUnit: AVAudioUnit?
        var capturedError: Error?
        var didComplete = false

        let instantiateBlock = {
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                capturedUnit = unit
                capturedError = error
                didComplete = true
                semaphore.signal()
            }
        }

        if Thread.isMainThread {
            instantiateBlock()
            while !didComplete {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        } else {
            DispatchQueue.main.async(execute: instantiateBlock)
            semaphore.wait()
        }

        if let capturedError {
            throw AppError.message("Plugin instantiation failed: \(capturedError.localizedDescription)")
        }
        guard let capturedUnit else {
            throw AppError.message("Plugin instantiation returned no unit")
        }
        return capturedUnit
    }

    private func setPluginRenderCallback(_ audioUnit: AudioUnit,
                                         callback: inout AURenderCallbackStruct) throws {
        let size = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        let statusGlobal = AudioUnitSetProperty(audioUnit,
                                                kAudioUnitProperty_SetRenderCallback,
                                                kAudioUnitScope_Global,
                                                0,
                                                &callback,
                                                size)
        if statusGlobal == noErr { return }

        let statusInput = AudioUnitSetProperty(audioUnit,
                                               kAudioUnitProperty_SetRenderCallback,
                                               kAudioUnitScope_Input,
                                               0,
                                               &callback,
                                               size)
        guard statusInput == noErr else {
            throw AppError.message("Plugin render callback setup failed (code \(statusInput))")
        }
    }

    private func maxFrames(for audioUnit: AudioUnit) throws -> UInt32 {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, &size)
        guard status == noErr else {
            throw AppError.message("Could not query max frames per slice (code \(status))")
        }
        return frames
    }

    private func setMaxFrames(_ frames: UInt32, for audioUnit: AudioUnit) throws {
        var mutableFrames = frames
        try setProperty(audioUnit, selector: kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, element: 0, data: &mutableFrames)
    }

    private func setMaxFramesBestEffort(_ frames: UInt32, for audioUnit: AudioUnit, context: String) {
        var mutableFrames = frames
        _ = setPropertyStatus(audioUnit,
                              selector: kAudioUnitProperty_MaximumFramesPerSlice,
                              scope: kAudioUnitScope_Global,
                              element: 0,
                              data: &mutableFrames)
    }

    private func initialize(audioUnit: AudioUnit) throws {
        let status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw AppError.message("Could not initialize audio unit (code \(status))")
        }
    }

    private func start(audioUnit: AudioUnit) throws {
        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw AppError.message("Could not start audio unit (code \(status))")
        }
    }

    private func prefillBufferForStableStart() throws {
        guard let ringBuffer else { return }
        let targetFrames = max(targetBufferFrames, Int(maxFramesPerSlice) * 2)
        let timeoutMicros = 200_000
        let stepMicros = 2_000
        var waited = 0

        while ringBuffer.availableFrameCount() < targetFrames && waited < timeoutMicros {
            usleep(useconds_t(stepMicros))
            waited += stepMicros
        }
    }

    private func setProperty<T>(_ audioUnit: AudioUnit,
                                selector: AudioUnitPropertyID,
                                scope: AudioUnitScope,
                                element: AudioUnitElement,
                                data: inout T) throws {
        let status = setPropertyStatus(audioUnit, selector: selector, scope: scope, element: element, data: &data)
        guard status == noErr else {
            throw AppError.message("AudioUnitSetProperty failed (selector \(selector), code \(status))")
        }
    }

    private func setPropertyStatus<T>(_ audioUnit: AudioUnit,
                                      selector: AudioUnitPropertyID,
                                      scope: AudioUnitScope,
                                      element: AudioUnitElement,
                                      data: inout T) -> OSStatus {
        withUnsafePointer(to: &data) { pointer in
            AudioUnitSetProperty(audioUnit,
                                 selector,
                                 scope,
                                 element,
                                 pointer,
                                 UInt32(MemoryLayout<T>.size))
        }
    }

    private func streamFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        streamFormat(sampleRate: sampleRate, channels: channels, interleaved: true)
    }

    private func streamFormat(sampleRate: Double, channels: UInt32, interleaved: Bool) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        let formatFlags: UInt32 = interleaved
            ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
            : (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags,
            mBytesPerPacket: interleaved ? (channels * bytesPerSample) : bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: interleaved ? (channels * bytesPerSample) : bytesPerSample,
            mChannelsPerFrame: channels,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
    }

    fileprivate func handleInput(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 timeStamp: UnsafePointer<AudioTimeStamp>,
                                 busNumber: UInt32,
                                 frameCount: UInt32) -> OSStatus {
        guard let inputUnit, let ringBuffer else { return noErr }
        let sampleCount = Int(frameCount * channels)
        if inputScratch.count < sampleCount {
            inputScratch = Array(repeating: 0, count: sampleCount)
        }

        var audioBuffer = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
            mData: nil
        )

        inputScratch.withUnsafeMutableBytes { bytes in
            audioBuffer.mData = bytes.baseAddress
        }

        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        let renderStatus = AudioUnitRender(inputUnit,
                                           ioActionFlags,
                                           timeStamp,
                                           busNumber,
                                           frameCount,
                                           &bufferList)
        guard renderStatus == noErr else { return renderStatus }

        if let data = bufferList.mBuffers.mData {
            let pointer = data.assumingMemoryBound(to: Float.self)
            let inputPeak = Self.computePeak(pointer, sampleCount: sampleCount)

            let pluginStatus = processThroughPluginIfNeeded(pointer: pointer, frameCount: Int(frameCount), timeStamp: timeStamp)
            if pluginStatus != noErr {
                return pluginStatus
            }

            updateInputMeter(with: inputPeak)
            ringBuffer.write(pointer, frames: Int(frameCount))
        }

        return noErr
    }

    private func processThroughPluginIfNeeded(pointer: UnsafeMutablePointer<Float>,
                                              frameCount: Int,
                                              timeStamp: UnsafePointer<AudioTimeStamp>) -> OSStatus {
        dspLock.lock()
        let plugins = hostedPlugins
        dspLock.unlock()
        if plugins.isEmpty { return noErr }

        let sampleCount = frameCount * Int(channels)
        if pluginInputScratch.count < sampleCount {
            pluginInputScratch = Array(repeating: 0, count: sampleCount)
        }
        if pluginOutputScratch.count < sampleCount {
            pluginOutputScratch = Array(repeating: 0, count: sampleCount)
        }

        var status: OSStatus = noErr
        for plugin in plugins {
            if plugin.bypassed { continue }

            pluginInputScratch.withUnsafeMutableBufferPointer { inputBuffer in
                pluginOutputScratch.withUnsafeMutableBufferPointer { outputBuffer in
                    guard let inputBase = inputBuffer.baseAddress,
                          let outputBase = outputBuffer.baseAddress else {
                        status = noErr
                        return
                    }

                    inputBase.update(from: pointer, count: sampleCount)
                    pluginFeedPointer = inputBase
                    pluginFeedFrames = frameCount

                    var renderFlags: AudioUnitRenderActionFlags = []
                    if plugin.nonInterleavedIO && Int(channels) > 1 {
                        let byteCount = MemoryLayout<AudioBufferList>.size + (Int(channels) - 1) * MemoryLayout<AudioBuffer>.size
                        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
                        defer { raw.deallocate() }
                        let bufferListPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
                        bufferListPtr.pointee.mNumberBuffers = channels
                        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPtr)

                        for channel in 0..<Int(channels) {
                            let channelStart = channel * frameCount
                            buffers[channel] = AudioBuffer(
                                mNumberChannels: 1,
                                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                                mData: outputBase.advanced(by: channelStart)
                            )
                        }

                        status = AudioUnitRender(plugin.audioUnit,
                                                 &renderFlags,
                                                 timeStamp,
                                                 0,
                                                 UInt32(frameCount),
                                                 bufferListPtr)
                    } else {
                        var audioBuffer = AudioBuffer(
                            mNumberChannels: channels,
                            mDataByteSize: UInt32(frameCount) * channels * UInt32(MemoryLayout<Float>.size),
                            mData: outputBase
                        )
                        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                        status = AudioUnitRender(plugin.audioUnit,
                                                 &renderFlags,
                                                 timeStamp,
                                                 0,
                                                 UInt32(frameCount),
                                                 &bufferList)
                    }

                    pluginFeedPointer = nil
                    pluginFeedFrames = 0

                    if status == noErr {
                        if plugin.nonInterleavedIO && Int(channels) > 1 {
                            for frame in 0..<frameCount {
                                for channel in 0..<Int(channels) {
                                    let planarIndex = channel * frameCount + frame
                                    let interleavedIndex = frame * Int(channels) + channel
                                    pointer[interleavedIndex] = outputBase[planarIndex]
                                }
                            }
                        } else {
                            pointer.update(from: outputBase, count: sampleCount)
                        }
                    }
                }
            }

            if status != noErr {
                break
            }
        }
        return status
    }

    fileprivate func handleOutput(ioData: UnsafeMutablePointer<AudioBufferList>?, frameCount: UInt32) -> OSStatus {
        guard let ioData, let ringBuffer else { return noErr }

        let mutableAudioBufferList = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = Int(frameCount)
        let sampleCount = frames * Int(channels)

        if outputScratch.count < sampleCount {
            outputScratch = Array(repeating: 0, count: sampleCount)
        }

        let bufferedFramesBeforeRead = ringBuffer.availableFrameCount()
        if bufferedFramesBeforeRead > highWaterBufferFrames {
            let framesToDrop = min(bufferedFramesBeforeRead - targetBufferFrames, Int(maxFramesPerSlice))
            if framesToDrop > 0 {
                _ = ringBuffer.discard(frames: framesToDrop)
            }
        } else if bufferedFramesBeforeRead < lowWaterBufferFrames {
            // Allow natural refill by input side; output path uses sample-hold on short read.
        }

        outputScratch.withUnsafeMutableBufferPointer { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else { return }
            let framesRead = ringBuffer.read(baseAddress, frames: frames, fillRemainingWithZero: false)
            if framesRead > 0 {
                let lastFrameStart = (framesRead - 1) * Int(channels)
                for channel in 0..<Int(channels) {
                    lastOutputFrame[channel] = baseAddress[lastFrameStart + channel]
                }
            }
            if framesRead < frames {
                // Hold the last valid sample on underrun to reduce zipper/click artifacts.
                for frame in framesRead..<frames {
                    let frameBase = frame * Int(channels)
                    for channel in 0..<Int(channels) {
                        baseAddress[frameBase + channel] = lastOutputFrame[channel]
                    }
                }
            }
            let outputPeak = Self.computePeak(baseAddress, sampleCount: sampleCount)
            let outputEnergy = Self.computeEnergy(baseAddress, sampleCount: sampleCount)
            updateOutputMeter(with: outputPeak)
            updateOutputLUFS(withEnergy: outputEnergy, sampleCount: sampleCount)

            if mutableAudioBufferList.count == 1, let data = mutableAudioBufferList[0].mData {
                data.copyMemory(from: baseAddress, byteCount: sampleCount * MemoryLayout<Float>.size)
                mutableAudioBufferList[0].mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
            } else {
                for channel in 0..<mutableAudioBufferList.count {
                    guard let channelData = mutableAudioBufferList[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<frames {
                        let srcIndex = (frame * Int(channels)) + min(channel, Int(channels) - 1)
                        channelData[frame] = baseAddress[srcIndex]
                    }
                    mutableAudioBufferList[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
                }
            }
        }

        return noErr
    }

    private func updateInputMeter(with peak: Float) {
        meterLock.lock()
        inputMeterLinear = max(peak, inputMeterLinear * 0.92)
        meterLock.unlock()
    }

    private func updateOutputMeter(with peak: Float) {
        meterLock.lock()
        outputMeterLinear = max(peak, outputMeterLinear * 0.92)
        meterLock.unlock()
    }

    private func updateOutputLUFS(withEnergy energy: Double, sampleCount: Int) {
        guard sampleCount > 0 else { return }
        meterLock.lock()
        outputIntegratedEnergy += energy
        outputIntegratedSamples += UInt64(sampleCount)
        let meanSquare = outputIntegratedEnergy / Double(max(1, outputIntegratedSamples))
        outputLufsDB = Self.lufsApprox(fromMeanSquare: meanSquare)
        meterLock.unlock()
    }

    private static func computePeak(_ pointer: UnsafePointer<Float>, sampleCount: Int) -> Float {
        guard sampleCount > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<sampleCount {
            peak = max(peak, abs(pointer[i]))
        }
        return peak
    }

    private static func computeEnergy(_ pointer: UnsafePointer<Float>, sampleCount: Int) -> Double {
        guard sampleCount > 0 else { return 0 }
        var energy: Double = 0
        for i in 0..<sampleCount {
            let sample = Double(pointer[i])
            energy += sample * sample
        }
        return energy
    }

    private static func dbFS(fromLinear linear: Float) -> Double {
        let value = max(Double(linear), 1e-6)
        return 20.0 * log10(value)
    }

    private static func lufsApprox(fromMeanSquare meanSquare: Double) -> Double {
        let value = max(sqrt(meanSquare), 1e-6)
        return 20.0 * log10(value) - 0.691
    }
}

private let inputRenderProc: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let engine = Unmanaged<RealtimeEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleInput(ioActionFlags: ioActionFlags,
                              timeStamp: inTimeStamp,
                              busNumber: inBusNumber,
                              frameCount: inNumberFrames)
}

private let outputRenderProc: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    let engine = Unmanaged<RealtimeEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleOutput(ioData: ioData, frameCount: inNumberFrames)
}

private let pluginInputRenderProc: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    let engine = Unmanaged<RealtimeEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioData, let sourcePointer = engine.pluginFeedPointer else { return noErr }

    let requestedFrames = Int(inNumberFrames)
    let availableFrames = engine.pluginFeedFrames
    let channelCount = Int(engine.channels)
    let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
    guard requestedFrames > 0, channelCount > 0 else { return noErr }

    if bufferList.count == 1 {
        guard let destination = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let requestedSamples = requestedFrames * channelCount
        let availableSamples = availableFrames * channelCount
        let copySamples = min(requestedSamples, availableSamples)

        destination.update(from: sourcePointer, count: copySamples)
        if copySamples < requestedSamples {
            let holdStart = max(0, copySamples - channelCount)
            for sampleIndex in copySamples..<requestedSamples {
                let channel = sampleIndex % channelCount
                destination[sampleIndex] = destination[holdStart + channel]
            }
        }

        bufferList[0].mDataByteSize = UInt32(requestedSamples * MemoryLayout<Float>.size)
        return noErr
    }

    for bufferIndex in 0..<bufferList.count {
        guard let destination = bufferList[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let channel = min(bufferIndex, channelCount - 1)
        let framesToCopy = min(requestedFrames, availableFrames)
        for frame in 0..<framesToCopy {
            destination[frame] = sourcePointer[(frame * channelCount) + channel]
        }
        if framesToCopy < requestedFrames {
            let heldValue = framesToCopy > 0 ? destination[framesToCopy - 1] : 0
            for frame in framesToCopy..<requestedFrames {
                destination[frame] = heldValue
            }
        }
        bufferList[bufferIndex].mDataByteSize = UInt32(requestedFrames * MemoryLayout<Float>.size)
    }

    return noErr
}
