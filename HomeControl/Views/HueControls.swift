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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                Text("Quick lighting moods").font(.caption).foregroundStyle(.secondary)
            }
            EqualHeightSceneLayout {
                ForEach(store.visibleScenes) { scene in
                    Button { store.recallScene(scene) } label: {
                        HueSceneCard(scene: scene, pending: store.pendingSceneID == scene.id)
                    }.buttonStyle(.plain)
                        .disabled(store.hueState != .online || store.pendingSceneID != nil || !store.pendingLights.isEmpty)
                        .help(scene.name + " · " + scene.groupName)
                        .accessibilityLabel(Text("Activate \(scene.name) in \(scene.groupName)"))
                        .accessibilityValue(store.pendingSceneID == scene.id ? Text("Waiting for device confirmation")
                                            : scene.isActive ? Text("Active") : Text("Inactive"))
                }
            }
        }
    }
}

private struct EqualHeightSceneLayout: Layout {
    private let columns = 3
    private let spacing: CGFloat = 8

    private func cardSize(width: CGFloat, subviews: Subviews) -> CGSize {
        let cardWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: cardWidth, height: ceil(height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? ((subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
                                      * CGFloat(columns) + CGFloat(columns - 1) * spacing)
        let card = cardSize(width: width, subviews: subviews)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * card.height + CGFloat(rows - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let card = cardSize(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * (card.width + spacing),
                                     y: bounds.minY + CGFloat(index / columns) * (card.height + spacing)),
                          anchor: .topLeading, proposal: ProposedViewSize(card))
        }
    }
}

private struct HueSceneCard: View {
    let scene: HueScene
    let pending: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var tint: Color { scene.primaryColor.map(Color.init(sceneColor:)) ?? .secondary }
    private var border: Color {
        // Blend a semantic color into the scene tint so white/yellow palettes still have a visible outline.
        let value = scene.primaryColor
        let base = colorScheme == .dark ? 1.0 : 0.0
        return value.map { Color(red: $0.red * 0.65 + base * 0.35,
                                 green: $0.green * 0.65 + base * 0.35,
                                 blue: $0.blue * 0.65 + base * 0.35) } ?? .secondary
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScenePaletteThumbnail(colors: scene.colors)
                .frame(width: 24, height: 24)
                .overlay {
                    if pending || scene.isActive {
                        ZStack {
                            Circle().fill(.black.opacity(0.6))
                            if pending { ProgressView().controlSize(.mini).tint(.white) }
                            else { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                        }.frame(width: 20, height: 20)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name).font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(scene.groupName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(colorScheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.52))
                .overlay { RoundedRectangle(cornerRadius: 11).fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.10)) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(border.opacity(scene.isActive ? 0.9 : 0.25), lineWidth: scene.isActive ? 1.5 : 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

private struct ScenePaletteThumbnail: View {
    let colors: [HueSceneColor]
    var body: some View {
        LinearGradient(colors: colors.isEmpty ? [Color.secondary.opacity(0.15), Color.secondary.opacity(0.3)]
                       : colors.map(Color.init(sceneColor:)), startPoint: .leading, endPoint: .trailing)
            .overlay {
                LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }
}

private extension Color {
    init(sceneColor: HueSceneColor) {
        self.init(.sRGB, red: sceneColor.red, green: sceneColor.green, blue: sceneColor.blue, opacity: 1)
    }
}
