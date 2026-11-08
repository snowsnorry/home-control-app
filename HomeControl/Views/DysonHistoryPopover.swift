import Charts
import SwiftUI

struct DysonHistoryPopover: View {
    let history: DysonHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dyson history").font(.headline)
                Spacer()
                Button { history.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh history")
                .accessibilityLabel("Refresh history")
                .disabled(history.isBusy)
            }

            if let data = history.data {
                DysonHistoryCharts(data: data)
            }
            if history.isBusy {
                ProgressView().controlSize(.small).accessibilityLabel("Loading MyDyson history")
            }
            if let error = history.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { history.open() }
        .onExitCommand { dismiss() }
    }
}

private enum HistoryMetric: Hashable {
    case airQuality, pollutant(DysonPollutant), temperature, humidity

    static let options: [Self] = [.airQuality] + DysonPollutant.allCases.map(Self.pollutant) + [.temperature, .humidity]

    var title: String {
        switch self {
        case .airQuality: String(localized: "Air quality")
        case .pollutant(let pollutant): pollutant.title
        case .temperature: String(localized: "Temperature")
        case .humidity: String(localized: "Humidity")
        }
    }

    var unit: String {
        switch self {
        case .airQuality: ""
        case .pollutant(let pollutant): pollutant.unit
        case .temperature: "°C"
        case .humidity: "%"
        }
    }

    var tint: Color {
        switch self {
        case .airQuality, .pollutant: .green
        case .temperature: .orange
        case .humidity: .teal
        }
    }

    var qualityBoundaries: [Double] {
        switch self {
        case .airQuality: AirQuality.allCases.dropFirst().map { Double($0.rawValue) }
        case .pollutant(let pollutant): pollutant.boundaries
        case .temperature, .humidity: []
        }
    }

    func quality(for value: Double) -> AirQuality? {
        switch self {
        case .airQuality: AirQuality(rawValue: min(Int(value), AirQuality.allCases.count - 1))
        case .pollutant(let pollutant): pollutant.quality(for: value)
        case .temperature, .humidity: nil
        }
    }

    func value(in sample: DysonHistory.Sample) -> Double? {
        switch self {
        case .airQuality: sample.airQualitySeverity
        case .pollutant(let pollutant): sample.pollutants[pollutant]
        case .temperature: sample.temperature
        case .humidity: sample.humidity
        }
    }
}

private struct DysonHistoryCharts: View {
    let data: DysonHistory
    @State private var period: Period = .today
    @State private var metric: HistoryMetric = .airQuality
    @State private var selectedDate: Date?
    @Environment(\.calendar) private var calendar

    private enum Period: Hashable { case today, week }

    var body: some View {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let start = period == .today ? today : calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        let periodSamples = data.samples.filter { $0.date >= start && $0.date < end && $0.date <= now }
        let latestIndex = periodSamples.lastIndex { metric.value(in: $0) != nil || $0.speed != nil }
            ?? periodSamples.lastIndex(where: \.hasReadings)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(period == .today ? today.formatted(date: .abbreviated, time: .omitted)
                     : "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(today.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("History period", selection: $period) {
                    Text("Today").tag(Period.today)
                    Text("Last 7 Days").tag(Period.week)
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: period) { selectedDate = nil }
            }

            if let latestIndex {
                let samples = Array(periodSamples[...latestIndex])
                let latest = periodSamples[latestIndex]
                let selection = samples.first(where: { $0.date == selectedDate }) ?? latest
                let chartStart = min(start, latest.date.addingTimeInterval(-DysonHistory.interval))
                let domain = chartStart...latest.date
                let ticks = timeTicks(start: start, end: latest.date)
                readout(selection, samples: samples)
                HStack {
                    Text("Metric").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Metric", selection: $metric) {
                        ForEach(HistoryMetric.options, id: \.self) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                let metricLabel = metric.unit.isEmpty ? metric.title : "\(metric.title) (\(metric.unit))"
                DysonHistoryChart(
                    title: metricLabel, tint: metric.tint, series: series(samples, value: metric.value),
                    domain: domain, ticks: ticks, selected: selection.date,
                    selectedValue: metric.value(in: selection), showsTimeLabels: false, weekly: period == .week,
                    metric: metric,
                    select: { select($0, in: samples) }
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Airflow speed").font(.subheadline.weight(.semibold))
                    Text("15-minute average").font(.caption).foregroundStyle(.secondary)
                }
                DysonHistoryChart(
                    title: String(localized: "Airflow speed"), tint: .blue, series: series(samples, value: displayedSpeed),
                    domain: domain, ticks: ticks, selected: selection.date,
                    selectedValue: displayedSpeed(selection), showsTimeLabels: true, weekly: period == .week, maximum: 10,
                    select: { select($0, in: samples) }
                )
            } else {
                Text("No history for this period.").foregroundStyle(.secondary)
            }
        }
    }

    private func readout(_ sample: DysonHistory.Sample, samples: [DysonHistory.Sample]) -> some View {
        let time = period == .today
            ? sample.date.formatted(date: .omitted, time: .shortened)
            : sample.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let value = metric.value(in: sample)
        let reading = metric == .airQuality
            ? value.flatMap { metric.quality(for: $0) }?.title ?? "—"
            : "\(metric.title) \(formatted(value, unit: metric.unit))"
        let speed = formatted(displayedSpeed(sample))
        return HStack(spacing: 8) {
            Text(time).fontWeight(.medium)
            Spacer(minLength: 4)
            Text(reading).lineLimit(1).minimumScaleFactor(0.8)
            Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Speed \(speed)")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .focusable()
        .onMoveCommand { direction in
            if direction == .left { step(-1, from: sample, in: samples) }
            if direction == .right { step(1, from: sample, in: samples) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1, from: sample, in: samples)
            case .decrement: step(-1, from: sample, in: samples)
            @unknown default: break
            }
        }
    }

    private func displayedSpeed(_ sample: DysonHistory.Sample) -> Double? {
        sample.speed?.rounded()
    }

    private func formatted(_ value: Double?, unit: String = "") -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + (unit.isEmpty ? "" : " " + unit)
    }

    private func timeTicks(start: Date, end: Date) -> [Date] {
        let values = period == .today ? [0, 6, 12, 18] : Array(0..<7)
        return values.compactMap { calendar.date(byAdding: period == .today ? .hour : .day, value: $0, to: start) }
            .filter { $0 < end }
    }

    private func select(_ date: Date, in samples: [DysonHistory.Sample]) {
        guard let first = samples.first else { return }
        let index = Int((date.timeIntervalSince(first.date) / DysonHistory.interval).rounded())
        if samples.indices.contains(index) { selectedDate = samples[index].date }
    }

    private func step(_ offset: Int, from sample: DysonHistory.Sample, in samples: [DysonHistory.Sample]) {
        select(sample.date.addingTimeInterval(Double(offset) * DysonHistory.interval), in: samples)
    }

    private func series(_ samples: [DysonHistory.Sample], value: (DysonHistory.Sample) -> Double?) -> [HistoryPoint] {
        var readings: [(date: Date, value: Double, segment: Int)] = []
        var segment = 0
        for sample in samples {
            if let reading = value(sample) {
                readings.append((sample.date, reading, segment))
            } else {
                segment += 1
            }
        }
        return readings.enumerated().map { index, reading in
            let startsSegment = index == 0 || readings[index - 1].segment != reading.segment
            let endsSegment = index == readings.count - 1 || readings[index + 1].segment != reading.segment
            return HistoryPoint(id: reading.date, value: reading.value, segment: reading.segment, isolated: startsSegment && endsSegment)
        }
    }
}

private struct HistoryPoint: Identifiable {
    let id: Date
    let value: Double
    let segment: Int
    let isolated: Bool
}

private struct DysonHistoryChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let tint: Color
    let series: [HistoryPoint]
    let domain: ClosedRange<Date>
    let ticks: [Date]
    let selected: Date
    let selectedValue: Double?
    let showsTimeLabels: Bool
    let weekly: Bool
    var maximum: Double? = nil
    var metric: HistoryMetric? = nil
    let select: (Date) -> Void

    private var floorValue: Double {
        guard metric == .temperature, let lowest = series.map(\.value).min() else { return 0 }
        return floor(lowest - 1)
    }

    private var ceiling: Double {
        if metric == .airQuality { return Double(AirQuality.allCases.count) }
        if metric == .humidity { return 100 }
        if metric == .temperature, let highest = series.map(\.value).max() { return ceil(highest + 1) }
        guard let maximum else {
            let highest = max(2, series.map(\.value).max() ?? 0)
            let step = pow(10, floor(log10(highest))) / 2
            return ceil(highest / step) * step
        }
        return maximum
    }

    private func color(for value: Double) -> Color {
        guard let quality = metric?.quality(for: value) else { return tint }
        let color = Color(rgb: quality.indicatorColor)
        // Keep thin yellow and green strokes legible on a light plot background.
        return colorScheme == .light ? color.mix(with: .black, by: 0.35) : color
    }

    private var lineColor: AnyShapeStyle {
        guard let boundaries = metric?.qualityBoundaries, !boundaries.isEmpty else { return AnyShapeStyle(tint) }
        var stops = [Gradient.Stop(color: color(for: 0), location: 0)]
        for boundary in boundaries where boundary <= ceiling {
            let location = boundary / ceiling
            // Two stops at the same height keep the app's discrete quality bands.
            stops.append(.init(color: color(for: boundary.nextDown), location: location))
            stops.append(.init(color: color(for: boundary), location: location))
        }
        stops.append(.init(color: color(for: ceiling), location: 1))
        return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top))
    }

    var body: some View {
        let stroke = lineColor
        Chart {
            ForEach(series) { point in
                if point.isolated {
                    PointMark(x: .value("Time", point.id), y: .value(title, point.value))
                        .foregroundStyle(color(for: point.value)).symbolSize(12)
                } else {
                    LineMark(x: .value("Time", point.id), y: .value(title, point.value), series: .value("Segment", point.segment))
                        .foregroundStyle(stroke)
                        .alignsMarkStylesWithPlotArea()
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            RuleMark(x: .value("Selected time", selected))
                .foregroundStyle(.secondary.opacity(0.7)).accessibilityHidden(true)
            if let selectedValue {
                PointMark(x: .value("Selected time", selected), y: .value(title, selectedValue))
                    .foregroundStyle(color(for: selectedValue)).symbolSize(38).accessibilityHidden(true)
            }
        }
        .chartXScale(domain: domain, range: .plotDimension(padding: 4))
        // A zero-inset pollution scale aligns gradient transitions exactly with
        // their data thresholds. Point marks may extend beyond the plot bounds.
        .chartYScale(domain: floorValue...ceiling, range: .plotDimension(padding: metric?.qualityBoundaries.isEmpty == false ? 0 : 4))
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                if showsTimeLabels, let date = value.as(Date.self) {
                    AxisValueLabel(anchor: .topLeading) {
                        Text(weekly ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [floorValue, (floorValue + ceiling) / 2, ceiling]) { value in
                AxisGridLine()
                if let amount = value.as(Double.self) {
                    AxisValueLabel {
                        Text(axisLabel(for: amount))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let bounds = geometry[plot]
                    let lastDate = series.last?.id ?? domain.upperBound
                    Rectangle().fill(.clear)
                        .frame(width: bounds.width, height: bounds.height)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let point) = phase else { return }
                            if let lastX = proxy.position(forX: lastDate), point.x >= lastX {
                                select(lastDate)
                            } else if let date = proxy.value(atX: point.x, as: Date.self) {
                                select(date)
                            }
                        }
                        .position(x: bounds.midX, y: bounds.midY)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: showsTimeLabels ? 121 : 104)
        .accessibilityLabel(title)
        .overlay {
            if series.isEmpty {
                Text("No readings").font(.caption).foregroundStyle(.secondary)
                    .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .allowsHitTesting(false)
            }
        }
    }

    private func axisLabel(for value: Double) -> String {
        if metric == .airQuality {
            if value == floorValue { return String(localized: "Good") }
            if value == ceiling { return String(localized: "Severe") }
            return ""
        }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
