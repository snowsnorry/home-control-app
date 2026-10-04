import SwiftUI

struct SettingsView: View {
    var store: HomeStore
    @Bindable var wizard: ConnectionWizard
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Devices").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                ForEach(DeviceKind.allCases) { kind in
                    Button {
                        wizard.cancel(); wizard.selected = kind
                    } label: {
                        Label(kind == .hue ? "Philips Hue" : "Dyson TP07", systemImage: kind == .hue ? "lightbulb" : "fan")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(wizard.selected == kind ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Home Control").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(width: 165).background(.regularMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(wizard.selected == .hue ? "Philips Hue" : "Dyson TP07").font(.title2.bold())
                    if wizard.success && (wizard.selected == .hue ? store.hueState : store.dysonState) == .online { Label("Connected successfully", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    if !wizard.active { connectionSummary }
                    else if wizard.selected == .hue { hueWizard }
                    else { dysonWizard }
                    if let error = wizard.error { ErrorNotice(message: error) }
                    if let error = wizard.discovery.error { ErrorNotice(message: error) }
                    if let error = store.storageError { ErrorNotice(message: error) }
                    if wizard.busy { ProgressView().controlSize(.small) }
                    if wizard.active {
                        Button("Cancel") { wizard.cancel() }.keyboardShortcut(.cancelAction)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: 660, height: 540)
    }
    @ViewBuilder private var connectionSummary: some View {
        let connected = wizard.selected == .hue ? store.configuration.hue != nil : store.configuration.dyson != nil
        let state = wizard.selected == .hue ? store.hueState : store.dysonState
        Text(LocalizedStringKey(state.rawValue)).foregroundStyle(.secondary)
        if connected {
            if wizard.selected == .hue, let config = store.configuration.hue { LabeledContent("Bridge", value: config.host) }
            if wizard.selected == .dyson, let config = store.configuration.dyson {
                LabeledContent("Device", value: config.name)
                LabeledContent("Address", value: config.host)
                Toggle("Continuous monitoring", isOn: Binding(get: { store.dyson.continuousMonitoring }, set: { store.setDyson(["rhtm": $0 ? "ON" : "OFF"]) }))
                    .disabled(store.dysonState != .online || store.dysonPending)
                Text("Keeps temperature and humidity monitoring active while the fan is in standby.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Reconnect") { store.reconnect(wizard.selected) }
                Button("Set Up Again…") { wizard.begin(wizard.selected) }
                Button("Remove Connection", role: .destructive) { store.remove(wizard.selected) }
            }
        } else {
            Text(wizard.selected == .hue ? "Connect a Hue Bridge on your local network." : "Connect the TP07 already set up in MyDyson.").foregroundStyle(.secondary)
            Button("Connect") { wizard.begin(wizard.selected) }.buttonStyle(.borderedProminent)
        }
        if let error = wizard.selected == .hue ? store.hueError : store.dysonError { ErrorNotice(message: error) }
        if wizard.selected == .hue, store.configuration.hue != nil { HueSceneSettings(store: store) }
        Divider()
        Text("Device integrations have not yet been verified with your physical devices.").font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var hueWizard: some View {
        if let configuration = wizard.identifiedHue {
            Label("Bridge verified", systemImage: "checkmark.shield")
            Text(configuration.host).foregroundStyle(.secondary)
            Text("Press the round link button on your Hue Bridge, then click Connect.")
            Button("Connect") { wizard.pair(store: store) }.buttonStyle(.borderedProminent).disabled(wizard.busy)
            Button("Choose Another Bridge") { wizard.identifiedHue = nil }.disabled(wizard.busy)
        } else {
            discovery(kind: .hue)
            TextField("Bridge IP address or hostname", text: $wizard.hueHost)
                .onChange(of: wizard.hueHost) { wizard.bridgeID = wizard.discovery.devices.first(where: { $0.host == wizard.hueHost })?.bridgeID }
            Text("Your Mac and Hue Bridge must be on the same network.").font(.caption).foregroundStyle(.secondary)
            Button("Continue") { wizard.identify(store: store) }.buttonStyle(.borderedProminent).disabled(wizard.busy || wizard.hueHost.isEmpty)
        }
    }
    @ViewBuilder private var dysonWizard: some View {
        Picker("Setup method", selection: $wizard.manualDyson) {
            Text("MyDyson").tag(false)
            Text("Manual").tag(true)
        }.pickerStyle(.segmented).disabled(wizard.busy)
            .onChange(of: wizard.manualDyson) { _, _ in
                let manual = wizard.manualDyson
                wizard.begin(.dyson); wizard.manualDyson = manual
            }
        if wizard.manualDyson {
            Text("Use the device's local MQTT credentials, not your home Wi-Fi password.").font(.caption).foregroundStyle(.secondary)
            discovery(kind: .dyson)
            TextField("IP address or hostname", text: $wizard.host)
            TextField("Serial number", text: $wizard.serial)
            SecureField("MQTT credential", text: $wizard.credential)
            TextField("Product type / topic prefix", text: $wizard.topicPrefix)
            Text("TP07 uses a 438 topic prefix, sometimes with E, K or M. Use the value from your device credentials.").font(.caption).foregroundStyle(.secondary)
            Button("Connect") { wizard.connectDyson(store: store) }.buttonStyle(.borderedProminent)
                .disabled(wizard.busy || wizard.host.isEmpty || wizard.serial.isEmpty || wizard.credential.isEmpty)
        } else if !wizard.devices.isEmpty {
            Picker("Device", selection: $wizard.selectedCloudID) {
                ForEach(wizard.devices) { device in Text(device.name).tag(Optional(device.id)) }
            }
            discovery(kind: .dyson)
            TextField("IP address or hostname", text: $wizard.host)
            Text("Select the matching device discovered on your network, or enter its address from your router.").font(.caption).foregroundStyle(.secondary)
            Button("Connect") { wizard.connectDyson(store: store) }.buttonStyle(.borderedProminent).disabled(wizard.busy || wizard.host.isEmpty)
        } else {
            TextField("Account email", text: $wizard.email).disabled(wizard.codeSent)
            TextField("Account country code (e.g. CZ)", text: $wizard.country).disabled(wizard.codeSent)
            if wizard.codeSent {
                SecureField("MyDyson password", text: $wizard.password)
                TextField("Verification code from email", text: $wizard.code)
                Button("Sign In") { wizard.verify() }.buttonStyle(.borderedProminent).disabled(wizard.busy || wizard.password.isEmpty || wizard.code.isEmpty)
                Button("Send a New Code") { wizard.requestCode() }.disabled(wizard.busy)
            } else {
                Button("Send Verification Code") { wizard.requestCode() }.buttonStyle(.borderedProminent).disabled(wizard.busy || wizard.email.isEmpty)
            }
            Text("MyDyson is used only to retrieve local device credentials. Your password and verification code are not saved.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func discovery(kind: DeviceKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Local network devices").font(.headline)
                Spacer()
                if wizard.discovery.isSearching { ProgressView().controlSize(.small) }
                Button("Search Again") { wizard.discovery.start(kind: kind) }.disabled(wizard.busy)
            }
            ForEach(wizard.discovery.devices) { device in
                Button {
                    if kind == .hue { wizard.hueHost = device.host; wizard.bridgeID = device.bridgeID }
                    else { wizard.host = device.host }
                } label: {
                    HStack { Text(device.name); Spacer(); Text(device.host).foregroundStyle(.secondary) }
                }.disabled(wizard.busy)
            }
            if wizard.discovery.devices.isEmpty && !wizard.discovery.isSearching {
                Text("No devices found. You can enter an address manually.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
