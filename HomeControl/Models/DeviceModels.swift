import Foundation

enum DeviceKind: String, CaseIterable, Identifiable { case hue, dyson; var id: String { rawValue } }
enum ConnectionState: String { case notConnected = "Not connected", connecting = "Connecting", online = "Online", offline = "Offline", authorizationRequired = "Authorization required" }
struct HueConfiguration: Codable, Equatable, Sendable {
    var host: String
    var bridgeID: String
    // Optional so configurations saved before scene selection still decode.
    var selectedSceneIDs: [String]? = nil
}
struct DysonConfiguration: Codable, Equatable, Sendable { var host: String; var serial: String; var topicPrefix: String; var name: String }
struct SavedConfiguration: Codable { var hue: HueConfiguration?; var dyson: DysonConfiguration? }
struct HueLight: Identifiable, Equatable, Sendable {
    var id: String; var name: String; var isOn: Bool; var brightness: Double?; var reachable: Bool
    var archetype: String = "unknown_archetype"
    var colorXY: HueXY?
    var mirek: Double?
    var effect: String?
    var supportsBrightness: Bool { brightness != nil }
    // Hue's configured icon distinguishes a lamp on a plug from an unrelated appliance.
    var isLightingDevice: Bool { supportsBrightness || archetype != "plug" }
}

struct HueXY: Equatable, Sendable {
    var x: Double
    var y: Double
}

struct HueSceneAction: Equatable, Sendable {
    static let brightnessTolerance = 3.0 // Percentage points on Hue's 0...100 scale.
    static let colorTolerance = 0.01 // Distance in CIE xy coordinates.
    static let temperatureTolerance = 5.0 // Mirek.
    var lightID: String
    var on: Bool?
    var brightness: Double?
    var colorXY: HueXY?
    var mirek: Double?
    var effect: String?
    var supportsMatching: Bool = true

    func matches(_ light: HueLight, dynamic: Bool) -> Bool {
        guard light.reachable, on == nil || light.isOn == on else { return false }
        // Off lamps retain their previous brightness and color on the bridge.
        if on == false || dynamic { return true }
        guard supportsMatching else { return false }
        if let effect, light.effect != effect { return false }
        if let brightness {
            guard let actual = light.brightness, abs(actual - brightness) <= Self.brightnessTolerance else { return false }
        }
        if let colorXY {
            guard light.mirek == nil, let actual = light.colorXY,
                  hypot(actual.x - colorXY.x, actual.y - colorXY.y) <= Self.colorTolerance else { return false }
        }
        if let mirek {
            guard let actual = light.mirek, abs(actual - mirek) <= Self.temperatureTolerance else { return false }
        }
        return true
    }
}
struct HueScene: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var groupID: String
    var groupName: String
    var active: String?
    var colors: [HueSceneColor] = []
    var actions: [HueSceneAction] = []
    var matchesLights: Bool?
    // Hue supplies an ordered palette, with no separate dominant-color field.
    var primaryColor: HueSceneColor? { colors.first }
    var isActive: Bool { matchesLights ?? (active == "static" || active == "dynamic_palette") }
    var enabledLightIDs: Set<String> { Set(actions.filter { $0.on == true }.map(\.lightID)) }

    func matches(_ lights: [HueLight]) -> Bool {
        guard !enabledLightIDs.isEmpty else { return false }
        let memberIDs = Set(actions.map(\.lightID))
        guard !lights.contains(where: { $0.isOn && $0.isLightingDevice && !memberIDs.contains($0.id) }) else { return false }
        let byID = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return actions.allSatisfy { action in
            guard let light = byID[action.lightID] else { return false }
            return action.matches(light, dynamic: active == "dynamic_palette")
        }
    }
}

/// Display colors are normalized independently of lamp brightness, so dim scenes remain recognizable.
struct HueSceneColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static func xy(x: Double, y: Double) -> HueSceneColor? {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0.00001, x + y <= 1 else { return nil }
        let X = x / y
        let Z = (1 - x - y) / y
        // Hue Wide RGB D65 matrix and inverse sRGB transfer function.
        // https://github.com/home-assistant/core/blob/dev/homeassistant/util/color.py
        let linear = [1.656492 * X - 0.354851 - 0.255038 * Z,
                      -0.707196 * X + 1.655397 + 0.036152 * Z,
                      0.051713 * X - 0.121364 + 1.011530 * Z]
        let rgb = linear.map { value in
            max(0, value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055)
        }
        let scale = max(1, rgb.max() ?? 1)
        return HueSceneColor(red: rgb[0] / scale, green: rgb[1] / scale, blue: rgb[2] / scale)
    }

    static func temperature(mirek: Double) -> HueSceneColor? {
        guard mirek.isFinite, (153...500).contains(mirek) else { return nil }
        let temperature = 10_000 / mirek
        // Black-body approximation by Tanner Helland, also used by Home Assistant.
        let red = temperature <= 66 ? 255 : 329.698727446 * pow(temperature - 60, -0.1332047592)
        let green = temperature <= 66 ? 99.4708025861 * log(temperature) - 161.1195681661
            : 288.1221695283 * pow(temperature - 60, -0.0755148492)
        let blue = temperature >= 66 ? 255 : (temperature <= 19 ? 0 : 138.5177312231 * log(temperature - 10) - 305.0447927307)
        return HueSceneColor(red: min(255, max(0, red)) / 255,
                             green: min(255, max(0, green)) / 255, blue: min(255, max(0, blue)) / 255)
    }
}
struct HueBridgeSnapshot: Equatable, Sendable {
    var lights: [HueLight] = []
    var scenes: [HueScene] = []
}
struct SensorReading: Equatable, Sendable {
    var value: Double?
    var receivedAt: Date
    func isFresh(at date: Date) -> Bool { value != nil && date.timeIntervalSince(receivedAt) < 120 }
}
enum DysonPollutant: CaseIterable, Sendable {
    case pm25, pm10, voc, nitrogenDioxide

    var title: String {
        switch self { case .pm25: "PM2.5"; case .pm10: "PM10"; case .voc: "VOC"; case .nitrogenDioxide: "NO₂" }
    }
    var unit: String { self == .pm25 || self == .pm10 ? "µg/m³" : "" }
    var fraction: Int { self == .pm25 || self == .pm10 ? 0 : 1 }
    var boundaries: [Double] {
        switch self {
        case .pm25: [36, 54, 71, 151, 251]
        case .pm10: [51, 76, 101, 351, 421]
        case .voc, .nitrogenDioxide: [4, 7, 9]
        }
    }
    func reading(in snapshot: DysonSnapshot) -> SensorReading? {
        switch self {
        case .pm25: snapshot.pm25
        case .pm10: snapshot.pm10
        case .voc: snapshot.voc
        case .nitrogenDioxide: snapshot.nitrogenDioxide
        }
    }
    func quality(for value: Double) -> AirQuality? {
        guard value.isFinite, value >= 0 else { return nil }
        return AirQuality(rawValue: boundaries.filter { value >= $0 }.count)
    }
    // Compare unlike units on the existing quality scale. Within a band,
    // interpolate toward the next boundary; keep the final band below the next
    // quality level so high gas indices cannot outrank severe particle pollution.
    func severity(for value: Double) -> Double {
        let limits = [0.0] + boundaries
        for index in 0..<(limits.count - 1) where value < limits[index + 1] {
            return Double(index) + (value - limits[index]) / (limits[index + 1] - limits[index])
        }
        let last = limits.count - 1
        return Double(last) + min((value - limits[last]) / (limits[last] - limits[last - 1]), 0.999)
    }
}
struct DysonPollutantReading {
    var pollutant: DysonPollutant
    var reading: SensorReading
    var severity: Double
    var quality: AirQuality {
        pollutant.quality(for: reading.value!)!
    }
}
struct DysonSnapshot: Equatable, Sendable {
    var isOn = false
    var autoMode = false
    var speed: Int?
    var continuousMonitoring = false
    var temperature: SensorReading?
    var humidity: SensorReading?
    var pm25: SensorReading?
    var pm10: SensorReading?
    var voc: SensorReading?
    var nitrogenDioxide: SensorReading?
    var hasState = false

    func airQuality(at date: Date, connected: Bool) -> AirQuality? {
        guard connected else { return nil }
        return dominantPollutant(at: date)?.quality
    }

    func dominantPollutant(at date: Date, requireFresh: Bool = true) -> DysonPollutantReading? {
        var dominant: DysonPollutantReading?
        for pollutant in DysonPollutant.allCases {
            guard let reading = pollutant.reading(in: self), let value = reading.value,
                  value.isFinite, value >= 0, !requireFresh || reading.isFresh(at: date) else { continue }
            let severity = pollutant.severity(for: value)
            // Keep declaration order for exact ties, rather than switching labels.
            if dominant == nil || severity > dominant!.severity {
                dominant = DysonPollutantReading(pollutant: pollutant, reading: reading, severity: severity)
            }
        }
        return dominant
    }
}
enum AirQuality: Int, CaseIterable {
    case good, fair, poor, veryPoor, extremelyPoor, severe
    var title: String {
        switch self {
        case .good: String(localized: "Good air quality")
        case .fair: String(localized: "Fair air quality")
        case .poor: String(localized: "Poor air quality")
        case .veryPoor: String(localized: "Very poor air quality")
        case .extremelyPoor: String(localized: "Extremely poor air quality")
        case .severe: String(localized: "Severe air pollution")
        }
    }
    var indicatorColor: UInt32 {
        switch self {
        case .good: 0x00CC00
        case .fair: 0xFFE600
        case .poor: 0xFF8800
        case .veryPoor: 0xFF3029
        case .extremelyPoor: 0xFF76D6
        case .severe: 0x9950FF
        }
    }
    var lightBackground: UInt32 {
        switch self { case .good: 0xEAF2EC; case .fair: 0xF5F0DF; case .poor: 0xF6EBDD; case .veryPoor: 0xF5E6E6; case .extremelyPoor: 0xF7E4F0; case .severe: 0xEDE4FA }
    }
    var darkBackground: UInt32 {
        switch self { case .good: 0x26362C; case .fair: 0x3A3525; case .poor: 0x3D3024; case .veryPoor: 0x3D2729; case .extremelyPoor: 0x402A3A; case .severe: 0x342943 }
    }
}
struct DiscoveredDevice: Identifiable, Equatable { var id: String; var name: String; var host: String; var bridgeID: String? }
struct CloudDysonDevice: Identifiable, Sendable { var serial: String; var name: String; var topicPrefix: String; var credential: String; var id: String { serial } }

enum ControlError: LocalizedError {
    case message(String)
    case offline, authorization, timeout, incompatibleBridge, localNetworkDenied
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        case .offline: String(localized: "Device is offline. Reconnect before sending commands.")
        case .authorization: String(localized: "Access was denied. Check your credentials or reconnect.")
        case .timeout: String(localized: "The device did not confirm the change within 10 seconds.")
        case .incompatibleBridge: String(localized: "This bridge does not support Hue API v2. Use a modern Hue Bridge.")
        case .localNetworkDenied: String(localized: "Local network access is unavailable. Enable Home Control in System Settings → Privacy & Security → Local Network.")
        }
    }
}

func validatedHost(_ input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 253, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }), !value.contains("://") else {
        throw ControlError.message(String(localized: "Enter an IP address or hostname without a URL or port."))
    }
    return value
}
