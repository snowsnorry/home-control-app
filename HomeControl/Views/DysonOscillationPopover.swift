import SwiftUI

struct DysonOscillationButton: View {
    var enabled: Bool?
    var span: Int?
    var open: () -> Void

    private var value: Text {
        if enabled == false { return Text("Off") }
        if let span { return Text("\(span)°") }
        return Text(verbatim: "—")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Image(systemName: "arrowtriangle.left.fill")
                    Image(systemName: "arrowtriangle.right.fill")
                }
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
                value.textCase(.uppercase).monospacedDigit()
                    .frame(minWidth: 29, alignment: .leading)
            }
            .modifier(DysonControlPill(selected: enabled == true))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Oscillation")
        .accessibilityValue(value)
        .help("Adjust oscillation")
    }
}

struct DysonOscillationPopover: View {
    var store: HomeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let snapshot = store.dyson
        let span = snapshot.oscillationEnabled == false ? 0 : snapshot.activeOscillationRange?.span
        let center = snapshot.oscillationCenter
        let canAdjust = store.canAdjustDysonOscillation
        let pendingRange = store.dysonPendingOscillationRange

        VStack(spacing: 13) {
            HStack {
                Text("Oscillation").font(.headline)
                Spacer()
                if store.dysonPending {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Waiting for device confirmation")
                }
            }

            DysonOscillationDial(
                displayedCenter: pendingRange?.center ?? center,
                span: pendingRange?.span ?? span,
                canMove: span == 0 || snapshot.activeOscillationRange?.canMove == true,
                canSubmit: canAdjust
            ) { direction in
                if let span { store.setDysonOscillationRange(center: direction, span: span) }
            }
            .frame(width: 246, height: 246)

            Group {
                if let center, pendingRange == nil, snapshot.oscillationEnabled == false,
                   snapshot.fixedOscillationDirection == nil, snapshot.stoppedOscillationAngle == nil {
                    Text("Last set center: \(center.formatted(.number.precision(.fractionLength(0...1))))°")
                } else if center == nil, pendingRange == nil {
                    Text("Center position unavailable")
                } else {
                    Text(verbatim: " ").hidden().accessibilityHidden(true)
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                preset(Text("Off"), selected: span == 0, action: store.stopDysonOscillation)
                ForEach(DysonOscillationRange.presets, id: \.self) { angle in
                    preset(Text("\(angle)°"), selected: span == angle) {
                        store.selectDysonOscillationSpan(angle)
                    }
                }
            }
            .disabled(!canAdjust)

            if let error = store.dysonError {
                ErrorNotice(message: error).frame(maxWidth: .infinity, alignment: .leading)
            } else if !canAdjust && !store.dysonPending {
                Text("Oscillation controls unavailable").font(.caption).foregroundStyle(.secondary)
            }

            Button { dismiss() } label: {
                Text("Done").fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 336)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { dismiss() }
    }

    private func preset(_ title: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title.textCase(.uppercase).monospacedDigit()
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.primary.opacity(selected ? 0.15 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(selected ? 0.90 : 0.18), lineWidth: selected ? 1.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DysonOscillationDial: View {
    var displayedCenter: Double?
    var span: Int?
    var canMove: Bool
    var canSubmit: Bool
    var change: (Double) -> Void
    @State private var dragAngle: Double?
    @GestureState private var dragging = false

    private enum Space: Hashable { case dial }
    private let violet = Color(rgb: 0x914FF5)
    private var center: Double { displayedCenter ?? DysonOscillationRange.forward }
    private var adjustable: Bool { canMove && canSubmit }

    var body: some View {
        GeometryReader { geometry in
            let origin = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(origin.x, origin.y) - 19
            let preview = dragAngle.flatMap { angle in span.flatMap { DysonOscillationRange(center: angle, span: $0) } }
            let direction = preview?.center ?? center
            let handle = point(direction, radius: radius, origin: origin)

            ZStack {
                Canvas { context, _ in
                    let innerRadius = radius * 0.56
                    var ticks = Path()
                    for angle in stride(from: 5, through: 355, by: 5) {
                        ticks.move(to: point(Double(angle), radius: innerRadius, origin: origin))
                        ticks.addLine(to: point(Double(angle), radius: radius, origin: origin))
                    }
                    context.stroke(ticks, with: .color(.primary.opacity(0.23)), lineWidth: 2.5)

                    if let span, span > 0 {
                        let half = Double(span) / 2
                        var sector = Path()
                        sector.addArc(center: origin, radius: (innerRadius + radius) / 2,
                                      startAngle: .degrees(direction - half - 90),
                                      endAngle: .degrees(direction + half - 90), clockwise: false)
                        context.stroke(sector, with: .color(violet), lineWidth: radius - innerRadius)
                    }

                    var pointer = Path()
                    pointer.move(to: origin)
                    pointer.addLine(to: handle)
                    context.stroke(pointer, with: .color(.primary), lineWidth: 2.5)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)

                productImage.resizable().scaledToFit()
                    .frame(width: radius, height: radius)
                    .rotationEffect(.degrees(direction - DysonOscillationRange.forward))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                Circle()
                    .fill(.background)
                    .overlay { Circle().strokeBorder(.primary, lineWidth: 3.5) }
                    .frame(width: 32, height: 32)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .gesture(drag(origin: origin), including: adjustable ? .all : .none)
                    .focusable(canMove)
                    .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                        guard adjustable else { return .ignored }
                        adjust(by: press.key == .leftArrow ? 1 : -1)
                        return .handled
                    }
                    .accessibilityLabel("Center direction")
                    .accessibilityValue(displayedCenter == nil && preview == nil
                        ? Text("Center position unavailable")
                        : Text("\(direction.formatted(.number.precision(.fractionLength(0...1))))°"))
                    .accessibilityAdjustableAction { action in
                        switch action {
                        case .increment: adjust(by: 1)
                        case .decrement: adjust(by: -1)
                        @unknown default: break
                        }
                    }
                    .disabled(!canMove)
                    .position(handle)
            }
            .coordinateSpace(.named(Space.dial))
        }
        .onChange(of: dragging) { _, active in
            if !active { dragAngle = nil }
        }
        .onChange(of: adjustable) { _, enabled in
            if !enabled { dragAngle = nil }
        }
    }

    private func drag(origin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Space.dial))
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { value in dragAngle = target(for: value, origin: origin) }
            .onEnded { value in
                guard adjustable else { return }
                change(target(for: value, origin: origin))
                dragAngle = nil
            }
    }

    private func target(for drag: DragGesture.Value, origin: CGPoint) -> Double {
        func angle(_ location: CGPoint, near reference: Double) -> Double {
            let raw = atan2(location.y - origin.y, location.x - origin.x) * 180 / .pi + 90
            return raw + ((reference - raw) / 360).rounded() * 360
        }
        let start = angle(drag.startLocation, near: center)
        let current = angle(drag.location, near: start + (dragAngle ?? center) - center)
        return center + current - start
    }

    private func point(_ degrees: Double, radius: CGFloat, origin: CGPoint) -> CGPoint {
        let radians = (degrees - 90) * .pi / 180
        return CGPoint(x: origin.x + radius * cos(radians), y: origin.y + radius * sin(radians))
    }

    private func adjust(by steps: Int) {
        if adjustable { change(center + Double(steps * DysonOscillationRange.step)) }
    }

    private var productImage: Image {
        if let image = Self.topView { return Image(nsImage: image) }
        return Image(systemName: "air.purifier")
    }

    private static let topView: NSImage? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "DysonTP07Top", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
