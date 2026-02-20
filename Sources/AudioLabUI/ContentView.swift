import CoreAudio
import SwiftUI

private enum Theme {
    static let bgTop = Color(red: 0.94, green: 0.97, blue: 1.0)
    static let bgBottom = Color(red: 0.90, green: 0.95, blue: 0.93)
    static let ink = Color(red: 0.10, green: 0.14, blue: 0.20)
    static let accent = Color(red: 0.08, green: 0.56, blue: 0.63)
    static let accentWarm = Color(red: 0.93, green: 0.43, blue: 0.28)
}

struct ContentView: View {
    @StateObject private var model = RealtimeViewModel()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            Circle()
                .fill(Theme.accent.opacity(0.20))
                .frame(width: 260, height: 260)
                .blur(radius: 38)
                .offset(x: -280, y: -230)

            Circle()
                .fill(Theme.accentWarm.opacity(0.17))
                .frame(width: 300, height: 300)
                .blur(radius: 44)
                .offset(x: 290, y: 230)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    devicesCard
                    pluginCard
                    levelsCard
                    statusCard
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Lab")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.ink)

                Text("Realtime input-to-output routing with dynamic AU plugin chain")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.70))
            }

            Spacer()

            Text(model.isRunning ? "RUNNING" : "IDLE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(model.isRunning ? Theme.accent.opacity(0.20) : Color.black.opacity(0.07))
                .overlay(
                    Capsule()
                        .stroke(model.isRunning ? Theme.accent : Color.black.opacity(0.18), lineWidth: 1)
                )
                .clipShape(Capsule())
                .foregroundStyle(model.isRunning ? Theme.accent : Theme.ink)
        }
    }

    private var devicesCard: some View {
        Card(title: "Devices") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Input")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.ink.opacity(0.78))

                        Picker("Input Device", selection: $model.selectedInputDeviceID) {
                            Text("None").tag(AudioDeviceID?.none)
                            ForEach(model.devices.filter(\.hasInput), id: \.id) { device in
                                Text("[\(device.id)] \(device.name)").tag(Optional(device.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.ink.opacity(0.78))

                        Picker("Output Device", selection: $model.selectedOutputDeviceID) {
                            Text("None").tag(AudioDeviceID?.none)
                            ForEach(model.devices.filter(\.hasOutput), id: \.id) { device in
                                Text("[\(device.id)] \(device.name)").tag(Optional(device.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Button("Refresh Device List") { model.refreshDevices() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var pluginCard: some View {
        Card(title: "Plugin Chain") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Available Plugin", selection: $model.selectedAvailablePluginID) {
                        Text("None").tag(String?.none)
                        ForEach(model.plugins) { plugin in
                            Text("\(plugin.name) (\(plugin.manufacturerName)) \(plugin.isAUv3 ? "[AUv3]" : "[AUv2]")").tag(Optional(plugin.id))
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Add To Chain") { model.addSelectedPluginToChain() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)

                    Button("Refresh Plugins") { model.refreshPlugins() }
                        .buttonStyle(.bordered)
                }

                if model.pluginChain.isEmpty {
                    Text("Plugin chain is empty.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.65))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.pluginChain) { chainItem in
                            HStack(spacing: 8) {
                                Toggle("On", isOn: Binding(
                                    get: { !chainItem.isBypassed },
                                    set: { model.setChainPluginBypassed(id: chainItem.id, bypassed: !$0) }
                                ))
                                .toggleStyle(.switch)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.ink)

                                Text(chainItem.descriptor.name)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.ink)

                                Text(chainItem.descriptor.isAUv3 ? "[AUv3]" : "[AUv2]")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.ink.opacity(0.55))

                                Spacer()

                                Button("Open Editor") { model.openPluginEditor(for: chainItem.id) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.accent)

                                Button("Up") { model.moveChainPluginUp(id: chainItem.id) }
                                    .buttonStyle(.bordered)
                                Button("Down") { model.moveChainPluginDown(id: chainItem.id) }
                                    .buttonStyle(.bordered)
                                Button("Remove") { model.removeChainPlugin(id: chainItem.id) }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(model.selectedChainPluginID == chainItem.id ? Theme.accent.opacity(0.10) : Color.clear)
                            )
                            .onTapGesture { model.selectedChainPluginID = chainItem.id }
                        }
                    }
                }

                Toggle("Allow AUv2 (unsafe)", isOn: $model.allowLegacyAUv2)
                    .toggleStyle(.switch)

                if !model.allowLegacyAUv2 {
                    Text("Safe mode: AUv3 only.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.65))
                }
            }
        }
    }

    private var levelsCard: some View {
        Card(title: "Levels") {
            VStack(alignment: .leading, spacing: 10) {
                LevelMeterRow(title: "Input", valueDB: model.inputMeterDBFS, minDB: -60, maxDB: 0, unit: "dBFS")
                LevelMeterRow(title: "Output", valueDB: model.outputMeterDBFS, minDB: -60, maxDB: 0, unit: "dBFS")
                LevelMeterRow(title: "LUFS-I", valueDB: model.outputLUFS, minDB: -50, maxDB: 0, unit: "LUFS")
            }
        }
    }

    private var statusCard: some View {
        Card(title: "Status") {
            HStack {
                Circle()
                    .fill(model.isRunning ? Theme.accent : Theme.ink.opacity(0.35))
                    .frame(width: 9, height: 9)

                Text(model.statusMessage)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)

                Spacer()

                Button("Start") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(model.isRunning)

                Button("Stop") { model.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!model.isRunning)
            }
        }
    }
}

private struct LevelMeterRow: View {
    let title: String
    let valueDB: Double
    let minDB: Double
    let maxDB: Double
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 58, alignment: .leading)
                .foregroundStyle(Theme.ink)

            GeometryReader { _ in
                MeterCanvas(valueDB: valueDB, minDB: minDB, maxDB: maxDB)
            }
            .frame(height: 14)

            Text(String(format: "%.1f %@", valueDB, unit))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 88, alignment: .trailing)
                .foregroundStyle(Theme.ink.opacity(0.78))
        }
        .frame(height: 18)
    }
}

private struct MeterCanvas: View {
    let valueDB: Double
    let minDB: Double
    let maxDB: Double

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, canvasSize in
            let span = max(1.0, maxDB - minDB)
            let normalized = max(0, min(1, (valueDB - minDB) / span))
            let width = canvasSize.width * normalized
            let meterColor: Color = valueDB > -6 ? .red : (valueDB > -18 ? .orange : Theme.accent)

            let backgroundRect = CGRect(origin: .zero, size: canvasSize)
            let backgroundPath = Path(roundedRect: backgroundRect, cornerSize: CGSize(width: 5, height: 5))
            context.fill(backgroundPath, with: .color(Color.black.opacity(0.10)))

            let levelRect = CGRect(x: 0, y: 0, width: max(2, width), height: canvasSize.height)
            let levelPath = Path(roundedRect: levelRect, cornerSize: CGSize(width: 5, height: 5))
            let gradient = Gradient(colors: [meterColor.opacity(0.7), meterColor])
            context.fill(
                levelPath,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: canvasSize.height * 0.5),
                    endPoint: CGPoint(x: max(2, width), y: canvasSize.height * 0.5)
                )
            )
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.ink)

            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
    }
}
