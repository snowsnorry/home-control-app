import SwiftUI

struct DevicePanel: View {
    var store: HomeStore
    var openSettings: (DeviceKind?) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Home Control", systemImage: "house.fill").font(.headline)
                Spacer()
                Button { openSettings(nil) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings…").accessibilityLabel("Settings")
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        sensor("Temperature", symbol: "thermometer.medium", reading: store.dyson.temperature, unit: "°C", fraction: 1)
                        sensor("Humidity", symbol: "humidity", reading: store.dyson.humidity, unit: "%", fraction: 0)
                    }
                    if let error = store.storageError { ErrorNotice(message: error) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            if store.configuration.hue == nil {
                                placeholder("Connect your Hue Bridge to control your lights.", kind: .hue)
                            } else if store.lights.isEmpty {
                                Text(store.hueState == .online ? "No lights found on this bridge." : "Waiting for your Hue Bridge…").foregroundStyle(.secondary)
                            } else {
                                ForEach(store.lights) { light in
                                    HueLightRow(light: light, enabled: store.hueState == .online && light.reachable && !store.pendingLights.contains(light.id), pending: store.pendingLights.contains(light.id)) { on, brightness in
                                        store.setLight(light, on: on, brightness: brightness)
                                    }
                                    if light.id != store.lights.last?.id { Divider() }
                                }
                            }
                            if let error = store.hueError { ErrorNotice(message: error) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    } label: { sectionLabel("Philips Hue", symbol: "lightbulb", state: store.hueState) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            if store.configuration.dyson == nil {
                                placeholder("Connect your Dyson TP07 to monitor and control the air purifier.", kind: .dyson)
                            } else {
                                Toggle("Power", isOn: Binding(get: { store.dyson.isOn }, set: { store.setDyson(["fpwr": $0 ? "ON" : "OFF"]) }))
                                Toggle("Auto", isOn: Binding(get: { store.dyson.autoMode }, set: { store.setDyson(["auto": $0 ? "ON" : "OFF"]) }))
                                DysonSpeedControl(speed: store.dyson.speed, autoMode: store.dyson.autoMode) { speed in
                                    store.setDyson(["auto": "OFF", "fpwr": "ON", "fnsp": String(format: "%04d", speed)])
                                }
                                if store.dysonPending { ProgressView().controlSize(.small).accessibilityLabel("Waiting for device confirmation") }
                            }
                            if let error = store.dysonError { ErrorNotice(message: error) }
                        }.disabled(store.configuration.dyson != nil && (store.dysonState != .online || store.dysonPending))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    } label: { sectionLabel("Dyson TP07", symbol: "fan", state: store.dysonState) }
                }.padding()
            }
        }.frame(width: 360).frame(maxHeight: 620)
    }
    private func sectionLabel(_ title: LocalizedStringKey, symbol: String, state: ConnectionState) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(LocalizedStringKey(state.rawValue)).font(.caption).foregroundStyle(state == .online ? .green : .secondary)
        }
    }
    private func placeholder(_ text: LocalizedStringKey, kind: DeviceKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Connect") { openSettings(kind) }.buttonStyle(.borderedProminent)
        }
    }
    private func sensor(_ title: LocalizedStringKey, symbol: String, reading: SensorReading?, unit: String, fraction: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            if let value = reading?.value {
                Text(value.formatted(.number.precision(.fractionLength(fraction))) + unit).font(.title2).monospacedDigit()
                if store.dysonState != .online || reading?.isFresh(at: store.now) != true {
                    Text("Last updated \(reading!.receivedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            } else { Text("—").font(.title2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct ErrorNotice: View {
    var message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            if message == ControlError.localNetworkDenied.localizedDescription {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
            }
        }
    }
}
struct HueLightRow: View {
    var light: HueLight
    var enabled: Bool
    var pending: Bool
    var change: (Bool?, Double?) -> Void
    @State private var draft: Double = 0
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { light.isOn }, set: { change($0, nil) })) {
                    VStack(alignment: .leading) {
                        Text(light.name)
                        if !light.reachable { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
                    }
                }.toggleStyle(.switch)
                if pending { ProgressView().controlSize(.small) }
            }
            if let brightness = light.brightness {
                HStack {
                    Slider(value: Binding(get: { editing ? draft : brightness }, set: { draft = $0 }), in: 1...100) { Text("Brightness") } onEditingChanged: { active in
                        if active { draft = brightness; editing = true }
                        else { editing = false; change(nil, draft) }
                    }.accessibilityLabel(Text("Brightness for \(light.name)"))
                    Text("\(Int(editing ? draft : brightness))%").font(.caption).monospacedDigit().frame(width: 35)
                }
            }
        }.disabled(!enabled)
    }
}
struct DysonSpeedControl: View {
    var speed: Int?
    var autoMode: Bool
    var change: (Int) -> Void
    @State private var draft = 1.0
    @State private var editing = false
    var body: some View {
        HStack {
            Text("Speed")
            Slider(value: Binding(get: { editing ? draft : Double(speed ?? 1) }, set: { draft = $0 }), in: 1...10, step: 1) { Text("Fan speed") } onEditingChanged: { active in
                if active { draft = Double(speed ?? 1); editing = true }
                else { editing = false; change(Int(draft)) }
            }
            Text(autoMode && !editing ? "Auto" : String(Int(editing ? draft : Double(speed ?? 1)))).font(.caption).monospacedDigit().frame(width: 30)
        }
    }
}
