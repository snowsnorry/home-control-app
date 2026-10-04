import Foundation

enum DeviceKind: String, CaseIterable, Identifiable { case hue, dyson; var id: String { rawValue } }
enum ConnectionState: String { case notConnected = "Not connected", connecting = "Connecting", online = "Online", offline = "Offline", authorizationRequired = "Authorization required" }
struct HueConfiguration: Codable, Equatable, Sendable { var host: String; var bridgeID: String }
struct DysonConfiguration: Codable, Equatable, Sendable { var host: String; var serial: String; var topicPrefix: String; var name: String }
struct SavedConfiguration: Codable { var hue: HueConfiguration?; var dyson: DysonConfiguration? }
struct HueLight: Identifiable, Equatable, Sendable {
    var id: String; var name: String; var isOn: Bool; var brightness: Double?; var reachable: Bool
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
    var hasState = false
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
