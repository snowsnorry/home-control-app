import SwiftUI

struct DevicePanel: View {
    var store: HomeStore
    var presentation: PanelPresentation
    var maximumHeight: CGFloat = 700
    var heightChanged: (CGFloat) -> Void = { _ in }
    var openSettings: (DeviceKind?) -> Void
    @State private var headerHeight: CGFloat = 64
    @State private var contentHeight: CGFloat = 400
    private var heightLimits: PanelHeightLimits { PanelHeightLimits(contentHeight: headerHeight + contentHeight, availableHeight: maximumHeight) }
    private var panelHeight: CGFloat { heightLimits.height(preferred: presentation.preferredPanelHeight) }
    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = store.storageError { ErrorNotice(message: error) }
                    if !store.visibleScenes.isEmpty { HueScenesView(store: store) }
                    lightsSection
                    Divider()
                    if store.configuration.dyson == nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Dyson TP07").font(.headline)
                            placeholder("Connect your Dyson TP07 to monitor and control the air purifier.", kind: .dyson)
                        }
                    } else { DysonCard(store: store) }
                }.padding(20)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
            }.scrollBounceBehavior(.basedOnSize)
            if heightLimits.canResize {
                PanelResizeHandle(height: panelHeight, limits: heightLimits) { height in
                    presentation.preferredPanelHeight = heightLimits.height(preferred: height)
                }
                .frame(height: PanelHeightLimits.resizeHandleHeight)
                .background {
                    Capsule().fill(.secondary.opacity(0.35)).frame(width: 30, height: 3)
                }
                .accessibilityRepresentation {
                    Slider(value: Binding(get: { panelHeight }, set: { height in
                        presentation.preferredPanelHeight = heightLimits.height(preferred: height)
                    }), in: heightLimits.minimum...heightLimits.maximum, step: 20) { Text("Panel height") }
                        .accessibilityValue(Text("\(Int(panelHeight)) points"))
                        .accessibilityHint("Adjust the panel height to show more content.")
                }
            }
        }.frame(width: 480, height: panelHeight, alignment: .top)
            .onChange(of: panelHeight, initial: true) { _, height in heightChanged(height) }
            .onChange(of: store.lights) { _, _ in dismissUnavailableLight() }
            .onChange(of: store.hueState) { _, _ in dismissUnavailableLight() }
    }
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "house.fill").font(.title2).accessibilityHidden(true)
                Text("Home Control").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button { openSettings(nil) } label: { Image(systemName: "gearshape").font(.title3) }
                    .buttonStyle(.borderless).help("Settings…").accessibilityLabel("Settings")
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var lightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lights").font(.headline)
                Spacer()
                if store.configuration.hue != nil {
                    if store.hueState == .online {
                        Text("\(store.lights.filter(\.isOn).count) on").font(.subheadline).foregroundStyle(.secondary)
                    } else { ConnectionLabel(state: store.hueState) }
                }
            }
            if store.configuration.hue == nil {
                placeholder("Connect your Hue Bridge to control your lights.", kind: .hue)
            } else if store.lights.isEmpty {
                Text(store.hueState == .online ? "No lights found on this bridge." : "Waiting for your Hue Bridge…").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(store.lights) { light in
                        HueLightCard(store: store, light: light, presentation: presentation)
                    }
                }
            }
            if let error = store.hueError { ErrorNotice(message: error) }
        }
    }
    private func dismissUnavailableLight() {
        guard let selection = presentation.selectedLight else { return }
        if store.hueState != .online || !store.lights.contains(where: { $0.id == selection.id && $0.reachable && $0.supportsBrightness }) {
            presentation.selectedLight = nil
        }
    }
    private func placeholder(_ text: LocalizedStringKey, kind: DeviceKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Connect") { openSettings(kind) }.buttonStyle(.borderedProminent)
        }
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
