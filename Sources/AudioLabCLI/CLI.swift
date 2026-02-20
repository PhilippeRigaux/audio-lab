import Foundation
import AudioLabCore

struct CLI {
    private let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func run() {
        guard arguments.count >= 2 else {
            printUsage()
            return
        }

        let command = arguments[1]
        do {
            switch command {
            case "realtime":
                let inputDevice = optionalValue(for: "--input-device")
                let outputDevice = optionalValue(for: "--output-device")
                let pluginIDs = values(for: "--plugin-id")
                let plugins = AUPluginManager.listEffectPlugins(includeLegacyAUv2: true)
                let descriptions = plugins.filter { pluginIDs.contains($0.id) }.map(\.componentDescription)

                let engine = RealtimeEngine(inputDeviceName: inputDevice,
                                            outputDeviceName: outputDevice,
                                            pluginComponentDescriptions: descriptions)
                try engine.start()
                print("Realtime audio router running. Press Ctrl+C to stop.")
                RunLoop.main.run()

            case "list-devices":
                let devices = try AudioDeviceManager.listDevices()
                if devices.isEmpty {
                    print("No audio devices found.")
                    return
                }
                print("Audio devices:")
                for device in devices {
                    let io = "\(device.hasInput ? "in" : "--")/\(device.hasOutput ? "out" : "---")"
                    print("  [\(device.id)] \(device.name) (\(io))")
                }

            case "list-plugins":
                let includeAUv2 = arguments.contains("--allow-auv2")
                let plugins = AUPluginManager.listEffectPlugins(includeLegacyAUv2: includeAUv2)
                if plugins.isEmpty {
                    print("No effect plugins found.")
                    return
                }
                print("Effect plugins:")
                for plugin in plugins {
                    print("  [\(plugin.id)] \(plugin.name) (\(plugin.manufacturerName)) \(plugin.isAUv3 ? "[AUv3]" : "[AUv2]")")
                }

            default:
                printUsage()
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private func optionalValue(for flag: String) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag), arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        return arguments[flagIndex + 1]
    }

    private func values(for flag: String) -> [String] {
        var result: [String] = []
        var i = 0
        while i < arguments.count {
            if arguments[i] == flag, arguments.indices.contains(i + 1) {
                result.append(arguments[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private func printUsage() {
        print(
            """
            Audio Lab

            Commands:
              realtime [--input-device \"Device Name or ID\"] [--output-device \"Device Name or ID\"] [--plugin-id <id> ...]
                Start live audio routing with optional plugin chain.

              list-devices
                Print available audio devices and IDs.

              list-plugins [--allow-auv2]
                Print available effect plugin IDs for use with --plugin-id.
            """
        )
    }
}
