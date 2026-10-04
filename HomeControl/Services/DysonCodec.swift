import Foundation

/// Stateless decoding keeps transport callbacks out of the UI model.
enum DysonCodec {
    static func updated(_ previous: DysonSnapshot, payload: Data, now: Date) throws -> DysonSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any], let message = object["msg"] as? String else {
            throw ControlError.message(String(localized: "Malformed Dyson message."))
        }
        var result = previous
        if message == "CURRENT-STATE" || message == "STATE-CHANGE", let fields = object["product-state"] as? [String: Any] {
            if let value = string(fields["fpwr"]) { result.isOn = value == "ON" }
            if let value = string(fields["auto"]) { result.autoMode = value == "ON" }
            if let value = string(fields["fnsp"]) { result.speed = Int(value).flatMap { (1...10).contains($0) ? $0 : nil } }
            if let value = string(fields["rhtm"]) { result.continuousMonitoring = value == "ON" }
            if let power = string(fields["fpwr"]), ["ON", "OFF"].contains(power) { result.hasState = true }
        }
        if message == "ENVIRONMENTAL-CURRENT-SENSOR-DATA", let fields = object["data"] as? [String: Any] {
            if fields["tact"] != nil {
                let value = number(fields["tact"]).map { $0 / 10 - 273.15 }
                result.temperature = SensorReading(value: value.flatMap { (-50...100).contains($0) ? $0 : nil }, receivedAt: now)
            }
            if fields["hact"] != nil {
                let value = number(fields["hact"])
                result.humidity = SensorReading(value: value.flatMap { (0...100).contains($0) ? $0 : nil }, receivedAt: now)
            }
        }
        return result
    }
    static func string(_ value: Any?) -> String? {
        if let values = value as? [Any] { return values.last as? String }
        return value as? String
    }
    static func number(_ value: Any?) -> Double? { string(value).flatMap(Double.init) }
    static func command(fields: [String: String], now: Date) throws -> String {
        try encode(message: "STATE-SET", additional: ["mode-reason": "LAPP", "data": fields], now: now)
    }
    static func encode(message: String, additional: [String: Any] = [:], now: Date) throws -> String {
        var object = additional
        object["msg"] = message
        object["time"] = ISO8601DateFormatter().string(from: now)
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        return String(decoding: data, as: UTF8.self)
    }
}
