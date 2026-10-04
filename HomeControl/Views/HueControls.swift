import SwiftUI

struct HueLightCard: View {
    var store: HomeStore
    var light: HueLight
    var presentation: PanelPresentation
    private var pending: Bool { store.pendingLights.contains(light.id) }
    private var powerControlWidth: CGFloat { pending ? 64 : 44 }
    private var enabled: Bool { store.hueState == .online && light.reachable && !store.pendingLights.contains(light.id) && store.pendingSceneID == nil }
    private var selection: Binding<PanelPresentation.LightSelection?> {
        Binding(get: { presentation.selectedLight?.id == light.id ? presentation.selectedLight : nil }, set: { value in
            if let value { presentation.selectedLight = value }
            else if presentation.selectedLight?.id == light.id { presentation.selectedLight = nil }
        })
    }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if light.supportsBrightness {
                    Button { presentation.selectedLight = .init(id: light.id) } label: { cardLabel }
                        .buttonStyle(.plain).disabled(!enabled)
                        .accessibilityLabel(Text("Adjust brightness for \(light.name)"))
                        .accessibilityValue(Text("\(Int(light.brightness ?? 0))%"))
                } else { cardLabel }
            }
            HStack(spacing: 6) {
                if pending { ProgressView().controlSize(.mini).accessibilityLabel("Waiting for device confirmation") }
                Toggle(isOn: Binding(get: { light.isOn }, set: { store.setLight(light, on: $0) })) { Text(light.name) }
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!enabled)
                    .accessibilityLabel(Text("Power for \(light.name)"))
            }
            .frame(width: powerControlWidth, height: 20, alignment: .trailing)
            .padding(12)
        }
        .modifier(PanelCard(selected: presentation.selectedLight?.id == light.id))
        .popover(item: selection, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) { selected in
            HueBrightnessPopover(store: store, lightID: selected.id)
        }
    }
    private var cardLabel: some View {
        HStack(spacing: 10) {
            DeviceIcon(light: light)
            VStack(alignment: .leading, spacing: 5) {
                Text(light.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(light.name)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Group {
                        if !light.reachable { Text("Unavailable") }
                        else if light.isOn, let brightness = light.brightness {
                            Text("On · \(Int(brightness))%")
                        } else { Text(light.isOn ? "On" : "Off") }
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 0)
                    // Reserve the power control's space while keeping it outside the card button.
                    Color.clear.frame(width: powerControlWidth, height: 20).accessibilityHidden(true)
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)
        }.padding(12).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

struct HueBrightnessPopover: View {
    var store: HomeStore
    var lightID: String
    @State private var draft = 1.0
    @State private var editing = false
    @State private var submitting = false
    @Environment(\.dismiss) private var dismiss
    private var light: HueLight? { store.lights.first { $0.id == lightID } }
    var body: some View {
        Group {
            if let light, let brightness = light.brightness {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Brightness").fontWeight(.medium)
                        Spacer()
                        if store.pendingLights.contains(lightID) {
                            ProgressView().controlSize(.mini).accessibilityLabel("Waiting for device confirmation")
                        }
                        Text("\(Int((editing || submitting ? draft : brightness).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    // A continuous slider avoids the dense native tick row on macOS.
                    Slider(value: Binding(get: { editing || submitting ? draft : max(1, brightness) }, set: { value in
                        draft = value
                        // Keyboard/accessibility adjustments don't produce a mouse editing session.
                        if !editing { submitting = true; store.setLight(light, on: true, brightness: value.rounded()) }
                    }), in: 1...100) { Text("Brightness") } onEditingChanged: { active in
                        if active { draft = max(1, brightness); editing = true }
                        else {
                            editing = false; submitting = true
                            store.setLight(light, on: true, brightness: draft.rounded())
                        }
                    }
                    .labelsHidden()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Brightness for \(light.name)"))
                    .disabled(store.hueState != .online || !light.reachable || store.pendingLights.contains(lightID) || store.pendingSceneID != nil)
                    if let error = store.hueError { ErrorNotice(message: error) }
                }
                .font(.subheadline)
                .padding(18)
                .frame(width: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
        }.onExitCommand { dismiss() }
            .onChange(of: store.pendingLights.contains(lightID)) { _, pending in if !pending { submitting = false } }
    }
}

struct HueScenesView: View {
    var store: HomeStore
    private let colors: [Color] = [.orange, .cyan, .purple]
    private let symbols = ["sunrise.fill", "sun.max.fill", "moon.fill"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                Text("Quick lighting moods").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(store.visibleScenes) { scene in
                    let index = store.visibleScenes.firstIndex(where: { $0.id == scene.id }) ?? 0
                    let color = colors[index % colors.count]
                    Button { store.recallScene(scene) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                if store.pendingSceneID == scene.id { ProgressView().controlSize(.mini) }
                                else { Image(systemName: symbols[index % symbols.count]).foregroundStyle(color).font(.title3).accessibilityHidden(true) }
                                Text(scene.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                            }
                            Text(scene.groupName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(10)
                            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(scene.isActive ? color.opacity(0.8) : color.opacity(0.25), lineWidth: scene.isActive ? 1.5 : 0.75) }
                            .contentShape(RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)
                        .disabled(store.hueState != .online || store.pendingSceneID != nil || !store.pendingLights.isEmpty)
                        .help(scene.name + " · " + scene.groupName)
                        .accessibilityLabel(Text("Activate \(scene.name) in \(scene.groupName)"))
                        .accessibilityValue(scene.isActive ? Text("Active") : Text("Inactive"))
                }
            }
        }
    }
}
