import SwiftUI

struct DysonCard: View {
    var store: HomeStore
    @Bindable var presentation: PanelPresentation
    @Environment(\.colorScheme) private var colorScheme
    private var enabled: Bool { store.dysonState == .online && !store.dysonPending }
    private var quality: AirQuality? { store.dyson.airQuality(at: store.now, connected: store.dysonState == .online) }
    private var dominantPollutant: DysonPollutantReading? {
        store.dyson.dominantPollutant(at: store.now)
            ?? store.dyson.dominantPollutant(at: store.now, requireFresh: false)
    }
    private var background: Color {
        guard let quality else { return Color.primary.opacity(0.04) }
        return Color(rgb: colorScheme == .dark ? quality.darkBackground : quality.lightBackground)
    }
    private var productImage: Image {
        if let image = PurifierAsset.image { return Image(nsImage: image) }
        return Image(systemName: "air.purifier")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Dyson TP07").font(.headline)
                Spacer()
                Button { store.setDyson(["fpwr": store.dyson.isOn ? "OFF" : "ON"]) } label: {
                    Image(systemName: "power").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(store.dyson.isOn ? Color.primary : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(store.dyson.isOn ? 0.10 : 0.04), in: Circle())
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75) }
                }.buttonStyle(.plain).disabled(!enabled)
                    .accessibilityLabel("Purifier power")
                    .accessibilityValue(store.dyson.isOn ? Text("On") : Text("Off"))
                    .help(store.dyson.isOn ? Text("Turn purifier off") : Text("Turn purifier on"))
                ConnectionLabel(state: store.dysonState)
            }
            HStack(spacing: 14) {
                productImage.resizable().scaledToFill().frame(width: 58, height: 156).clipped().accessibilityHidden(true)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.75)
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 8) {
                        SensorMetric(title: "Temperature", symbol: "thermometer.medium", reading: store.dyson.temperature, unit: "°C", fraction: 1, connected: store.dysonState == .online, now: store.now)
                        Divider().frame(height: 44)
                        SensorMetric(title: "Humidity", symbol: "humidity", reading: store.dyson.humidity, unit: "%", fraction: 0, connected: store.dysonState == .online, now: store.now)
                        Divider().frame(height: 44)
                        Button {
                            presentation.selectedLight = nil
                            presentation.showsPollutants.toggle()
                        } label: {
                            SensorMetric(title: LocalizedStringKey(dominantPollutant?.pollutant.title ?? "PM2.5"), symbol: (dominantPollutant?.pollutant ?? .pm25).symbol, reading: dominantPollutant?.reading, unit: dominantPollutant?.pollutant.unit ?? "µg/m³", fraction: dominantPollutant?.pollutant.fraction ?? 0, connected: store.dysonState == .online, now: store.now)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help("Show all pollutants")
                            .accessibilityHint("Show all pollutants")
                            .popover(isPresented: $presentation.showsPollutants, arrowEdge: .trailing) {
                                DysonPollutantsPopover(snapshot: store.dyson, connected: store.dysonState == .online, now: store.now)
                            }
                    }
                    Toggle("Auto", isOn: Binding(get: { store.dyson.autoMode }, set: { store.setDyson(["auto": $0 ? "ON" : "OFF"]) }))
                        .toggleStyle(DysonAutoToggleStyle())
                        .disabled(!enabled)
                        .accessibilityLabel("Purifier mode")
                        .accessibilityValue(store.dyson.autoMode ? Text("Auto") : Text("Manual"))
                    DysonSpeedControl(speed: store.dyson.speed, autoMode: store.dyson.autoMode) { speed in
                        store.setDyson(["auto": "OFF", "fpwr": "ON", "fnsp": String(format: "%04d", speed)])
                    }.disabled(!enabled)
                    HStack(spacing: 6) {
                        Image(systemName: quality == .good ? "aqi.low" : quality == .fair ? "aqi.medium" : "aqi.high").accessibilityHidden(true)
                        Text(quality?.title ?? String(localized: "Air quality unavailable")).lineLimit(2)
                        Spacer(minLength: 0)
                        if store.dysonPending { ProgressView().controlSize(.mini).accessibilityLabel("Waiting for device confirmation") }
                    }.font(.caption).foregroundStyle(.secondary).help(pollutantSummary)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(pollutantSummary)
                }.frame(maxWidth: .infinity)
            }.padding(14).background(background, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75) }
            if let error = store.dysonError { ErrorNotice(message: error) }
        }
    }
    private var pollutantSummary: String {
        DysonPollutant.allCases.map { pollutant in
            let label = pollutant.title, reading = pollutant.reading(in: store.dyson), unit = pollutant.unit
            guard let value = reading?.value else { return label + ": —" }
            let formatted = value.formatted(.number.precision(.fractionLength(0...1)))
            let stale = store.dysonState != .online || reading?.isFresh(at: store.now) != true
            let suffix = stale ? " · " + String(localized: "Last updated \(reading!.receivedAt.formatted(date: .omitted, time: .shortened))") : ""
            return label + ": " + formatted + (unit.isEmpty ? "" : " " + unit) + suffix
        }.joined(separator: "\n")
    }
}

private struct DysonAutoToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    private let charcoal = Color(rgb: 0x454746)

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(configuration.isOn ? charcoal : Color.secondary)
                    .accessibilityHidden(true)
                configuration.label
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(configuration.isOn ? charcoal : Color.primary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(configuration.isOn ? Color.white : Color.primary.opacity(0.08), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
            .shadow(color: .black.opacity(configuration.isOn ? 0.08 : 0), radius: 3, y: 1)
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

private struct DysonPollutantsPopover: View {
    var snapshot: DysonSnapshot
    var connected: Bool
    var now: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pollutants").font(.headline)
            ForEach(DysonPollutant.allCases, id: \.self) { pollutant in
                DysonPollutantRow(pollutant: pollutant, reading: pollutant.reading(in: snapshot), connected: connected, now: now)
            }
        }
        .padding(18)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { dismiss() }
    }
}

private struct DysonPollutantRow: View {
    var pollutant: DysonPollutant
    var reading: SensorReading?
    var connected: Bool
    var now: Date
    @Environment(\.colorScheme) private var colorScheme
    private var quality: AirQuality? { reading?.value.flatMap { pollutant.quality(for: $0) } }
    private var tint: Color {
        quality.map { Color(rgb: $0.indicatorColor) } ?? .secondary
    }
    private var background: Color {
        guard let quality else { return Color.primary.opacity(0.04) }
        return Color(rgb: colorScheme == .dark ? quality.darkBackground : quality.lightBackground)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
                Label(pollutant.title, systemImage: pollutant.symbol).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(quality == nil ? "—" : reading!.value!.formatted(.number.precision(.fractionLength(pollutant.fraction))))
                    .monospacedDigit().fontWeight(.semibold)
                if quality != nil, !pollutant.unit.isEmpty {
                    Text(pollutant.unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let reading, quality != nil, !connected || !reading.isFresh(at: now) {
                Text("Last updated \(reading.receivedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35), lineWidth: 0.75) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(quality?.title ?? String(localized: "Air quality unavailable"))
    }
}

private extension DysonPollutant {
    var symbol: String {
        switch self {
        case .pm25: "aqi.medium"
        case .pm10: "camera.macro"
        case .voc: "flask"
        case .nitrogenDioxide: "car"
        }
    }
}

struct SensorMetric: View {
    var title: LocalizedStringKey
    var symbol: String
    var reading: SensorReading?
    var unit: String
    var fraction: Int
    var connected: Bool
    var now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(reading?.value.map { $0.formatted(.number.precision(.fractionLength(fraction))) } ?? "—")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                if reading?.value != nil { Text(unit).font(.system(size: 10, weight: .medium)) }
            }.fixedSize(horizontal: true, vertical: false)
            Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            if let reading, reading.value != nil, !connected || !reading.isFresh(at: now) {
                Text("Last updated \(reading.receivedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

struct DysonSpeedControl: View {
    var speed: Int?
    var autoMode: Bool
    var change: (Int) -> Void
    @State private var draft = 1.0
    @State private var editing = false
    var body: some View {
        HStack(spacing: 12) {
            Label("Fan speed", systemImage: "fan")
                .font(.caption).fixedSize()
            Slider(value: Binding(get: { editing ? draft : Double(speed ?? 1) }, set: { value in
                draft = value
                if !editing { change(Int(value.rounded())) }
            }), in: 1...10, step: 1, label: { Text("Fan speed") }, tick: { _ in nil }, onEditingChanged: { active in
                if active { draft = Double(speed ?? 1); editing = true }
                else { editing = false; change(Int(draft.rounded())) }
            })
            .labelsHidden()
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Fan speed")
            .accessibilityValue(Text("\(Int((editing ? draft : Double(speed ?? 1)).rounded()))"))
            .help("Changing speed switches to Manual and turns the purifier on.")
            Text(autoMode && !editing ? String(localized: "Auto") : String(Int((editing ? draft : Double(speed ?? 1)).rounded())))
                .font(.caption).monospacedDigit().frame(width: 28, alignment: .trailing)
        }
    }
}

@MainActor private enum PurifierAsset {
    static let image: NSImage? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "DysonTP07", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
