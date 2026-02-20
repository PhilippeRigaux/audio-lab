import AVFoundation
import AudioToolbox
import Foundation

public struct AUPluginDescriptor: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let manufacturerName: String
    public let componentType: OSType
    public let componentSubType: OSType
    public let componentManufacturer: OSType
    public let isAUv3: Bool

    public init(name: String,
                manufacturerName: String,
                componentType: OSType,
                componentSubType: OSType,
                componentManufacturer: OSType,
                isAUv3: Bool) {
        self.name = name
        self.manufacturerName = manufacturerName
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.isAUv3 = isAUv3
        self.id = "\(componentType)-\(componentSubType)-\(componentManufacturer)-\(name)"
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

public enum AUPluginManager {
    private static let audioComponentFlagIsV3AudioUnit: UInt32 = 4

    public static func listEffectPlugins(includeLegacyAUv2: Bool = false) -> [AUPluginDescriptor] {
        let manager = AVAudioUnitComponentManager.shared()
        let all = manager.components(matching: AudioComponentDescription(
            componentType: 0,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        ))

        return all
            .filter { component in
                let desc = component.audioComponentDescription
                let type = desc.componentType
                let isAUv3 = (desc.componentFlags & audioComponentFlagIsV3AudioUnit) != 0
                return type == kAudioUnitType_Effect &&
                    !component.hasMIDIInput &&
                    !component.hasMIDIOutput &&
                    (includeLegacyAUv2 || isAUv3)
            }
            .map { component in
                let desc = component.audioComponentDescription
                return AUPluginDescriptor(
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    componentType: desc.componentType,
                    componentSubType: desc.componentSubType,
                    componentManufacturer: desc.componentManufacturer,
                    isAUv3: (desc.componentFlags & audioComponentFlagIsV3AudioUnit) != 0
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
