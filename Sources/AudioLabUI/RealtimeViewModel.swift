import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import AudioLabCore

struct PluginChainItem: Identifiable, Equatable {
    let id: UUID
    let descriptor: AUPluginDescriptor
    var isBypassed: Bool

    init(id: UUID = UUID(), descriptor: AUPluginDescriptor, isBypassed: Bool = false) {
        self.id = id
        self.descriptor = descriptor
        self.isBypassed = isBypassed
    }
}

@MainActor
final class RealtimeViewModel: NSObject, ObservableObject, NSWindowDelegate {
    private struct SendablePluginStateSnapshot: @unchecked Sendable {
        let value: RealtimeEngine.PluginState?
    }

    private enum DefaultsKey {
        static let lastInputDeviceID = "last_input_device_id"
        static let lastOutputDeviceID = "last_output_device_id"
        static let allowLegacyAUv2 = "allow_legacy_auv2"
    }

    @Published var devices: [AudioDevice] = []
    @Published var plugins: [AUPluginDescriptor] = []

    @Published var selectedInputDeviceID: AudioDeviceID? {
        didSet {
            persistDeviceSelections()
            handleDeviceSelectionChanged(oldValue: oldValue, newValue: selectedInputDeviceID)
        }
    }

    @Published var selectedOutputDeviceID: AudioDeviceID? {
        didSet {
            persistDeviceSelections()
            handleDeviceSelectionChanged(oldValue: oldValue, newValue: selectedOutputDeviceID)
        }
    }

    @Published var selectedAvailablePluginID: String?
    @Published var selectedChainPluginID: UUID?
    @Published var pluginChain: [PluginChainItem] = []
    @Published var allowLegacyAUv2: Bool = false {
        didSet { handleAllowLegacyAUv2Changed(oldValue: oldValue, newValue: allowLegacyAUv2) }
    }

    @Published var statusMessage: String = "Idle"
    @Published var isRunning: Bool = false

    @Published var inputMeterDBFS: Double = -120
    @Published var outputMeterDBFS: Double = -120
    @Published var outputLUFS: Double = -120

    private var engine: RealtimeEngine?
    private let engineQueue = DispatchQueue(label: "AudioLab.EngineQueue", qos: .userInitiated)
    private var engineTransitionInFlight = false
    private var isTerminating = false
    private var isRestoringSelections = false
    private var meterTimer: Timer?
    private var pluginEditorWindow: NSWindow?
    private var pluginEditorChainPluginID: UUID?
    private var pluginStateByID: [UUID: RealtimeEngine.PluginState] = [:]

    override init() {
        super.init()
        isRestoringSelections = true
        restoreSavedDeviceSelections()
        restorePluginSafetySetting()
        refreshDevices()
        refreshPlugins()
        isRestoringSelections = false
        startMeterPolling()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminateRequested),
            name: .audioLabTerminateRequested,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refreshDevices() {
        do {
            devices = try AudioDeviceManager.listDevices()
            if selectedInputDeviceID == nil {
                selectedInputDeviceID = devices.first(where: { $0.hasInput })?.id
            }
            if selectedOutputDeviceID == nil {
                selectedOutputDeviceID = devices.first(where: { $0.hasOutput })?.id
            }
            if let inputID = selectedInputDeviceID,
               !devices.contains(where: { $0.id == inputID && $0.hasInput }) {
                selectedInputDeviceID = devices.first(where: { $0.hasInput })?.id
            }
            if let outputID = selectedOutputDeviceID,
               !devices.contains(where: { $0.id == outputID && $0.hasOutput }) {
                selectedOutputDeviceID = devices.first(where: { $0.hasOutput })?.id
            }
            persistDeviceSelections()
            statusMessage = "Loaded \(devices.count) devices"
        } catch {
            statusMessage = "Failed to load devices: \(error.localizedDescription)"
        }
    }

    func refreshPlugins() {
        captureRunningPluginStates()
        let available = AUPluginManager.listEffectPlugins(includeLegacyAUv2: allowLegacyAUv2)
        plugins = available

        if let selectedAvailablePluginID,
           !available.contains(where: { $0.id == selectedAvailablePluginID }) {
            self.selectedAvailablePluginID = nil
        }

        let availableIDs = Set(available.map(\.id))
        let filteredChain = pluginChain.filter { availableIDs.contains($0.descriptor.id) }
        if filteredChain != pluginChain {
            let removedIDs = Set(pluginChain.map(\.id)).subtracting(filteredChain.map(\.id))
            for id in removedIDs {
                pluginStateByID.removeValue(forKey: id)
            }
            pluginChain = filteredChain
            if let selectedChainPluginID,
               !pluginChain.contains(where: { $0.id == selectedChainPluginID }) {
                self.selectedChainPluginID = nil
            }
            if isRunning {
                reconfigureRunningEngine(reason: "Plugin chain updated and engine switched")
            }
        }
    }

    func start() {
        guard !isTerminating else { return }
        guard !engineTransitionInFlight else {
            statusMessage = "Engine transition in progress..."
            return
        }

        guard selectedInputDeviceID != nil, selectedOutputDeviceID != nil else {
            statusMessage = "Select both input and output devices"
            return
        }

        engineTransitionInFlight = true
        statusMessage = "Starting engine..."

        let inputQuery = selectedInputDeviceID.map(String.init)
        let outputQuery = selectedOutputDeviceID.map(String.init)
        let pluginDescriptions = pluginChain.map { $0.descriptor.componentDescription }
        let pluginBypasses = pluginChain.map(\.isBypassed)
        let pluginStates = pluginChain.map { SendablePluginStateSnapshot(value: pluginStateByID[$0.id]) }

        engineQueue.async { [weak self] in
            let realtimeEngine = RealtimeEngine(inputDeviceName: inputQuery,
                                                outputDeviceName: outputQuery,
                                                pluginComponentDescriptions: pluginDescriptions)
            do {
                try realtimeEngine.start()
                realtimeEngine.applyPluginStates(pluginStates.map(\.value))
                for (index, bypassed) in pluginBypasses.enumerated() {
                    realtimeEngine.setPluginBypassed(index: index, bypassed: bypassed)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.isTerminating {
                        realtimeEngine.stop()
                        return
                    }
                    self.engine = realtimeEngine
                    self.isRunning = true
                    self.engineTransitionInFlight = false
                    self.statusMessage = "Running realtime audio router"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.engineTransitionInFlight = false
                    self.statusMessage = "Start failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        guard !isTerminating else { return }
        if engineTransitionInFlight {
            statusMessage = "Engine transition in progress..."
            return
        }
        destroyPluginEditorWindow()
        let oldEngine = engine
        engine = nil
        isRunning = false
        inputMeterDBFS = -120
        outputMeterDBFS = -120
        outputLUFS = -120
        statusMessage = "Stopped"
        engineQueue.async {
            oldEngine?.stop()
        }
    }

    func addSelectedPluginToChain() {
        captureRunningPluginStates()
        guard let selectedAvailablePluginID,
              let descriptor = plugins.first(where: { $0.id == selectedAvailablePluginID }) else {
            statusMessage = "Select a plugin to add"
            return
        }

        let item = PluginChainItem(descriptor: descriptor)
        pluginChain.append(item)
        selectedChainPluginID = item.id
        statusMessage = "Added plugin to chain"
        if isRunning {
            reconfigureRunningEngine(reason: "Plugin chain changed and engine switched")
        }
    }

    func removeChainPlugin(id: UUID) {
        captureRunningPluginStates()
        guard let index = pluginChain.firstIndex(where: { $0.id == id }) else { return }
        pluginChain.remove(at: index)
        pluginStateByID.removeValue(forKey: id)
        if selectedChainPluginID == id {
            selectedChainPluginID = pluginChain.indices.contains(index) ? pluginChain[index].id : pluginChain.last?.id
        }
        statusMessage = "Removed plugin from chain"
        if isRunning {
            reconfigureRunningEngine(reason: "Plugin chain changed and engine switched")
        }
    }

    func moveChainPluginUp(id: UUID) {
        captureRunningPluginStates()
        guard let index = pluginChain.firstIndex(where: { $0.id == id }), index > 0 else { return }
        pluginChain.swapAt(index, index - 1)
        selectedChainPluginID = id
        statusMessage = "Moved plugin up"
        if isRunning {
            reconfigureRunningEngine(reason: "Plugin chain order changed and engine switched")
        }
    }

    func moveChainPluginDown(id: UUID) {
        captureRunningPluginStates()
        guard let index = pluginChain.firstIndex(where: { $0.id == id }), index < pluginChain.count - 1 else { return }
        pluginChain.swapAt(index, index + 1)
        selectedChainPluginID = id
        statusMessage = "Moved plugin down"
        if isRunning {
            reconfigureRunningEngine(reason: "Plugin chain order changed and engine switched")
        }
    }

    func setChainPluginBypassed(id: UUID, bypassed: Bool) {
        guard let index = pluginChain.firstIndex(where: { $0.id == id }) else { return }
        pluginChain[index].isBypassed = bypassed
        engine?.setPluginBypassed(index: index, bypassed: bypassed)
        statusMessage = bypassed ? "Plugin off" : "Plugin on"
    }

    func openPluginEditor(for id: UUID) {
        guard let engine else {
            statusMessage = "Start audio engine first"
            return
        }
        guard let index = pluginChain.firstIndex(where: { $0.id == id }) else {
            statusMessage = "No chain plugin selected"
            return
        }
        if let existingWindow = pluginEditorWindow, pluginEditorChainPluginID == id {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            statusMessage = "Opened plugin editor"
            return
        }
        destroyPluginEditorWindow()
        selectedChainPluginID = id

        engine.requestPluginEditorViewController(index: index) { [weak self] controller in
            guard let self else { return }
            guard let controller else {
                self.statusMessage = "Plugin has no compatible editor UI"
                return
            }

            _ = controller.view
            let preferredSize = self.editorPreferredSize(for: controller)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: preferredSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Plugin Editor"
            window.center()
            window.contentMinSize = NSSize(width: max(480, preferredSize.width * 0.75),
                                           height: max(320, preferredSize.height * 0.75))
            window.contentMaxSize = NSSize(width: 2400, height: 1800)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.pluginEditorWindow = window
            self.pluginEditorChainPluginID = id
            self.statusMessage = "Opened plugin editor"
        }
    }

    private func restoreSavedDeviceSelections() {
        if let inputID = UserDefaults.standard.object(forKey: DefaultsKey.lastInputDeviceID) as? UInt32 {
            selectedInputDeviceID = inputID
        }
        if let outputID = UserDefaults.standard.object(forKey: DefaultsKey.lastOutputDeviceID) as? UInt32 {
            selectedOutputDeviceID = outputID
        }
    }

    private func restorePluginSafetySetting() {
        if UserDefaults.standard.object(forKey: DefaultsKey.allowLegacyAUv2) != nil {
            allowLegacyAUv2 = UserDefaults.standard.bool(forKey: DefaultsKey.allowLegacyAUv2)
        }
    }

    private func persistDeviceSelections() {
        guard !isRestoringSelections else { return }
        if let inputID = selectedInputDeviceID {
            UserDefaults.standard.set(inputID, forKey: DefaultsKey.lastInputDeviceID)
        }
        if let outputID = selectedOutputDeviceID {
            UserDefaults.standard.set(outputID, forKey: DefaultsKey.lastOutputDeviceID)
        }
    }

    private func persistPluginSafetySetting() {
        guard !isRestoringSelections else { return }
        UserDefaults.standard.set(allowLegacyAUv2, forKey: DefaultsKey.allowLegacyAUv2)
    }

    private func handleDeviceSelectionChanged(oldValue: AudioDeviceID?, newValue: AudioDeviceID?) {
        guard !isRestoringSelections, oldValue != newValue, isRunning else { return }
        captureRunningPluginStates()
        reconfigureRunningEngine(reason: "Audio device changed and engine switched")
    }

    private func handleAllowLegacyAUv2Changed(oldValue: Bool, newValue: Bool) {
        guard !isRestoringSelections, oldValue != newValue else { return }
        persistPluginSafetySetting()
        refreshPlugins()
        if !newValue {
            statusMessage = "AUv3-only mode enabled (safer)."
        }
    }

    private func reconfigureRunningEngine(reason: String) {
        guard !isTerminating else { return }
        guard !engineTransitionInFlight else { return }
        guard selectedInputDeviceID != nil, selectedOutputDeviceID != nil else {
            statusMessage = "Select both input and output devices"
            return
        }

        destroyPluginEditorWindow()
        let oldEngine = engine
        engine = nil
        inputMeterDBFS = -120
        outputMeterDBFS = -120
        outputLUFS = -120
        engineTransitionInFlight = true
        statusMessage = "Reconfiguring engine..."

        let inputQuery = selectedInputDeviceID.map(String.init)
        let outputQuery = selectedOutputDeviceID.map(String.init)
        let pluginDescriptions = pluginChain.map { $0.descriptor.componentDescription }
        let pluginBypasses = pluginChain.map(\.isBypassed)
        let pluginStates = pluginChain.map { SendablePluginStateSnapshot(value: pluginStateByID[$0.id]) }

        engineQueue.async { [weak self] in
            oldEngine?.stop()
            let realtimeEngine = RealtimeEngine(inputDeviceName: inputQuery,
                                                outputDeviceName: outputQuery,
                                                pluginComponentDescriptions: pluginDescriptions)
            do {
                try realtimeEngine.start()
                realtimeEngine.applyPluginStates(pluginStates.map(\.value))
                for (index, bypassed) in pluginBypasses.enumerated() {
                    realtimeEngine.setPluginBypassed(index: index, bypassed: bypassed)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.isTerminating {
                        realtimeEngine.stop()
                        return
                    }
                    self.engine = realtimeEngine
                    self.isRunning = true
                    self.engineTransitionInFlight = false
                    self.statusMessage = reason
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isRunning = false
                    self.engineTransitionInFlight = false
                    self.statusMessage = "Device switch failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startMeterPolling() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollMeters()
            }
        }
    }

    private func pollMeters() {
        guard let engine else {
            inputMeterDBFS = -120
            outputMeterDBFS = -120
            outputLUFS = -120
            return
        }

        let meters = engine.currentMeters()
        inputMeterDBFS = meters.inputPeakDBFS
        outputMeterDBFS = meters.outputPeakDBFS
        outputLUFS = meters.outputIntegratedLUFS
    }

    private func destroyPluginEditorWindow() {
        guard let window = pluginEditorWindow else { return }
        window.delegate = nil
        window.close()
        pluginEditorWindow = nil
        pluginEditorChainPluginID = nil
    }

    private func captureRunningPluginStates() {
        guard isRunning, let engine else { return }
        let states = engine.capturePluginStates()
        for (index, item) in pluginChain.enumerated() {
            guard states.indices.contains(index), let state = states[index] else { continue }
            pluginStateByID[item.id] = state
        }
    }

    private func editorPreferredSize(for controller: NSViewController) -> NSSize {
        let preferred = controller.preferredContentSize
        if preferred.width > 0, preferred.height > 0 {
            return NSSize(width: max(480, preferred.width), height: max(320, preferred.height))
        }

        let fitted = controller.view.fittingSize
        if fitted.width > 0, fitted.height > 0 {
            return NSSize(width: max(480, fitted.width), height: max(320, fitted.height))
        }

        return NSSize(width: 960, height: 700)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === pluginEditorWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    @objc private func handleTerminateRequested() {
        if isTerminating { return }
        isTerminating = true
        engineTransitionInFlight = false

        meterTimer?.invalidate()
        meterTimer = nil
        destroyPluginEditorWindow()

        let runningEngine = engine
        engine = nil
        isRunning = false
        inputMeterDBFS = -120
        outputMeterDBFS = -120
        outputLUFS = -120
        statusMessage = "Terminating..."
        engineQueue.async {
            runningEngine?.stop()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioLabTerminateReady, object: nil)
            }
        }
    }
}
