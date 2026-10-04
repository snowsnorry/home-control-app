import SwiftUI
import AppKit
import Observation

@MainActor @Observable final class PanelPresentation {
    struct LightSelection: Identifiable { let id: String }
    var selectedLight: LightSelection?
    var preferredPanelHeight: CGFloat?
    func closeBrightness() -> Bool {
        guard selectedLight != nil else { return false }
        selectedLight = nil
        return true
    }
}

struct PanelHeightLimits: Equatable {
    static let resizeHandleHeight: CGFloat = 12
    let minimum: CGFloat
    let maximum: CGFloat
    var canResize: Bool { maximum > minimum + 0.5 }

    init(contentHeight: CGFloat, availableHeight: CGFloat) {
        minimum = min(700, contentHeight, availableHeight)
        let handleHeight = contentHeight > minimum && availableHeight > minimum ? Self.resizeHandleHeight : 0
        maximum = min(contentHeight + handleHeight, availableHeight)
    }
    func height(preferred: CGFloat?) -> CGFloat { min(maximum, max(minimum, preferred ?? minimum)) }
}

/// Native mouse tracking keeps the drag in screen coordinates as the popover itself grows.
struct PanelResizeHandle: NSViewRepresentable {
    var height: CGFloat
    var limits: PanelHeightLimits
    var resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.height = height; view.limits = limits; view.resize = resize
        view.toolTip = String(localized: "Drag to resize the panel. Double-click to show all content.")
    }
    final class ResizeView: NSView {
        var height: CGFloat = 700
        var limits = PanelHeightLimits(contentHeight: 700, availableHeight: 700)
        var resize: (CGFloat) -> Void = { _ in }
        private var dragStart: (y: CGFloat, height: CGFloat)?
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 { resize(limits.maximum); return }
            guard let window else { return }
            dragStart = (window.convertPoint(toScreen: event.locationInWindow).y, height)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart, let window else { return }
            resize(limits.height(preferred: start.height + start.y - window.convertPoint(toScreen: event.locationInWindow).y))
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 125: resize(limits.height(preferred: height + 20))
            case 126: resize(limits.height(preferred: height - 20))
            case 115: resize(limits.minimum)
            case 119: resize(limits.maximum)
            default: super.keyDown(with: event)
            }
        }
    }
}

enum HueIcon {
    static func symbol(archetype: String, on: Bool) -> String {
        let base: String
        switch archetype {
        case "table_shade", "table_wash", "classic_bulb": base = archetype == "classic_bulb" ? "lightbulb" : "lamp.desk"
        case "floor_shade", "floor_wash": base = "lamp.floor"
        case "ceiling_round", "ceiling_square", "ceiling_horizontal", "ceiling_tube", "pendant_round", "pendant_long": base = "lamp.ceiling"
        case "hue_lightstrip", "hue_lightstrip_tv", "hue_lightstrip_pc": base = "light.ribbon"
        case "plug": base = "powerplug"
        case "spot_bulb", "recessed_ceiling": base = "light.recessed"
        default: base = "lightbulb"
        }
        return on ? base + ".fill" : base
    }
}

struct DeviceIcon: View {
    var light: HueLight
    @Environment(\.colorScheme) private var colorScheme
    private var litColor: Color { colorScheme == .dark ? Color(red: 1, green: 0.82, blue: 0.47) : Color(red: 0.59, green: 0.37, blue: 0.06) }
    var body: some View {
        Image(systemName: HueIcon.symbol(archetype: light.archetype, on: light.isOn))
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(light.isOn ? litColor : Color.secondary)
            .shadow(color: light.isOn ? litColor.opacity(0.22) : .clear, radius: 9)
            .frame(width: 40, height: 44)
            .accessibilityHidden(true)
    }
}

struct PanelCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var selected = false
    func body(content: Content) -> some View {
        content
            .background(colorScheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.5 : 0.75)
            }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}

struct ConnectionLabel: View {
    var state: ConnectionState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state == .online ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(LocalizedStringKey(state.rawValue)).font(.caption)
        }.foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}
