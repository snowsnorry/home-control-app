import Foundation

struct DysonHistory: Decodable, Equatable {
    static let interval: TimeInterval = 15 * 60
    let samples: [Sample]

    struct Sample: Identifiable, Equatable {
        let date: Date
        let pollutants: [DysonPollutant: Double]
        let speed: Double?
        var temperature: Double? = nil
        var humidity: Double? = nil
        var id: Date { date }
        var hasReadings: Bool { speed != nil || temperature != nil || humidity != nil || !pollutants.isEmpty }
        var airQualitySeverity: Double? {
            pollutants.map { $0.key.severity(for: $0.value) }.max()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case start = "start_time", resolution, speed = "fnsp"
        case pm25 = "p25m", pm10 = "p10m", voc = "volm", no2 = "no2m"
        case temperature = "tmpm", humidity = "humm"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(String.self, forKey: .start)
        guard try container.decode(String.self, forKey: .resolution) == "PT15M",
              let startDate = (try? Date.ISO8601FormatStyle().parse(start))
                ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(start)) else {
            throw DecodingError.dataCorruptedError(forKey: .start, in: container, debugDescription: "Invalid Dyson history time grid")
        }

        let speed = try container.decodeIfPresent([Double?].self, forKey: .speed) ?? []
        let temperature = try container.decodeIfPresent([Double?].self, forKey: .temperature) ?? []
        let humidity = try container.decodeIfPresent([Double?].self, forKey: .humidity) ?? []
        let fields: [(DysonPollutant, CodingKeys, Double)] = [
            (.pm25, .pm25, 1), (.pm10, .pm10, 1), (.voc, .voc, 10), (.nitrogenDioxide, .no2, 10)
        ]
        let series = try fields.map { pollutant, key, divisor in
            (pollutant, try container.decodeIfPresent([Double?].self, forKey: key) ?? [], divisor)
        }
        let count = max(speed.count, temperature.count, humidity.count, series.map { $0.1.count }.max() ?? 0)
        samples = (0..<count).map { index in
            var pollutants: [DysonPollutant: Double] = [:]
            for (pollutant, values, divisor) in series {
                pollutants[pollutant] = Self.value(at: index, in: values, limit: 9999).map { $0 / divisor }
            }
            let celsius = Self.value(at: index, in: temperature, limit: 5000).map { $0 / 10 - 273.15 }
            return Sample(date: startDate.addingTimeInterval(Double(index) * Self.interval), pollutants: pollutants,
                          speed: Self.value(at: index, in: speed, limit: 10),
                          temperature: celsius.flatMap { (-50...100).contains($0) ? $0 : nil },
                          humidity: Self.value(at: index, in: humidity, limit: 100))
        }
    }

    init(samples: [Sample]) {
        self.samples = samples
    }

    private static func value(at index: Int, in values: [Double?], limit: Double) -> Double? {
        guard values.indices.contains(index), let value = values[index], (0...limit).contains(value) else { return nil }
        return value
    }
}
