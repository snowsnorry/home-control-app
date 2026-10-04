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
    var supportsBrightness: Bool { brightness != nil }
}
struct HueScene: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var groupID: String
    var groupName: String
    var active: String?
    var isActive: Bool { active == "static" || active == "dynamic_palette" }
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
        let levels = [(pm25, [36.0, 54, 71]), (pm10, [51.0, 76, 101]),
                      (voc, [4.0, 7, 9]), (nitrogenDioxide, [4.0, 7, 9])]
            .compactMap { reading, boundaries -> AirQuality? in
                guard let reading, reading.isFresh(at: date), let value = reading.value,
                      value.isFinite, value >= 0 else { return nil }
                return AirQuality(rawValue: boundaries.filter { value >= $0 }.count)
            }
        return levels.max(by: { $0.rawValue < $1.rawValue })
    }
}
enum AirQuality: Int, CaseIterable {
    case good, fair, poor, veryPoor
    var title: String {
        switch self {
        case .good: String(localized: "Good air quality")
        case .fair: String(localized: "Fair air quality")
        case .poor: String(localized: "Poor air quality")
        case .veryPoor: String(localized: "Very poor air quality")
        }
    }
    var lightBackground: UInt32 {
        switch self { case .good: 0xEAF2EC; case .fair: 0xF5F0DF; case .poor: 0xF6EBDD; case .veryPoor: 0xF5E6E6 }
    }
    var darkBackground: UInt32 {
        switch self { case .good: 0x26362C; case .fair: 0x3A3525; case .poor: 0x3D3024; case .veryPoor: 0x3D2729 }
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
