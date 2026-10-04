import SwiftUI

struct DysonCard: View {
    var store: HomeStore
    @Environment(\.colorScheme) private var colorScheme
    private var enabled: Bool { store.dysonState == .online && !store.dysonPending }
    private var quality: AirQuality? { store.dyson.airQuality(at: store.now, connected: store.dysonState == .online) }
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
                        SensorMetric(title: "PM2.5", symbol: "leaf", reading: store.dyson.pm25, unit: "µg/m³", fraction: 0, connected: store.dysonState == .online, now: store.now)
                    }
                    Picker("Mode", selection: Binding(get: { store.dyson.autoMode }, set: { store.setDyson(["auto": $0 ? "ON" : "OFF"]) })) {
                        Text("Auto").tag(true)
                        Text("Manual").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().disabled(!enabled).accessibilityLabel("Purifier mode")
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
        [("PM2.5", store.dyson.pm25, "µg/m³"), ("PM10", store.dyson.pm10, "µg/m³"),
         ("VOC", store.dyson.voc, ""), ("NO₂", store.dyson.nitrogenDioxide, "")].map { label, reading, unit in
            guard let value = reading?.value else { return label + ": —" }
            let formatted = value.formatted(.number.precision(.fractionLength(0...1)))
            let stale = store.dysonState != .online || reading?.isFresh(at: store.now) != true
            let suffix = stale ? " · " + String(localized: "Last updated \(reading!.receivedAt.formatted(date: .omitted, time: .shortened))") : ""
            return label + ": " + formatted + (unit.isEmpty ? "" : " " + unit) + suffix
        }.joined(separator: "\n")
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
