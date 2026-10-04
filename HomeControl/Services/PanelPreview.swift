#if DEBUG
import Foundation

/// Deterministic UI inspection that never reads Keychain or contacts real devices.
@MainActor enum PanelPreview {
    static func makeStore(arguments: [String]) -> HomeStore {
        let hue = PreviewHue()
        let dyson = PreviewDyson()
        let persistence = PreviewConfiguration()
        let quality = arguments.first(where: { $0.hasPrefix("--preview-quality=") })?.split(separator: "=").last.map(String.init) ?? "good"
        dyson.snapshot.pm25 = SensorReading(value: ["good": 5, "fair": 42, "poor": 60, "red": 95][quality] ?? 5, receivedAt: Date())
        dyson.snapshot.pm10 = SensorReading(value: 10, receivedAt: Date())
        dyson.snapshot.voc = SensorReading(value: 1.2, receivedAt: Date())
        dyson.snapshot.nitrogenDioxide = SensorReading(value: 0.4, receivedAt: Date())
        if arguments.contains("--preview-scene-palettes") {
            hue.snapshot.scenes += [
                HueScene(id: "white", name: "Cool white", groupID: "room1", groupName: "Living room", active: "inactive", colors: [.temperature(mirek: 153)!]),
                HueScene(id: "warm", name: "Warm white with a longer scene name", groupID: "room1", groupName: "Living room", active: "inactive", colors: [.temperature(mirek: 450)!]),
                HueScene(id: "neutral", name: "No palette", groupID: "room1", groupName: "Living room", active: "inactive")
            ]
        }
        hue.snapshot.scenes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if arguments.contains("--preview-many") {
            for index in 5...20 { hue.snapshot.lights.append(HueLight(id: UUID().uuidString, name: "Living room pendant light with a long name \(index)", isOn: index.isMultiple(of: 2), brightness: 50, reachable: true, archetype: "pendant_round")) }
        }
        if arguments.contains("--preview-empty") { hue.snapshot = HueBridgeSnapshot(); persistence.saved = SavedConfiguration() }
        else {
            persistence.saved.hue = HueConfiguration(host: "preview.invalid", bridgeID: "preview", selectedSceneIDs: hue.snapshot.scenes.map(\.id))
            persistence.saved.dyson = DysonConfiguration(host: "preview.invalid", serial: "PREVIEW", topicPrefix: "438", name: "Dyson TP07")
        }
        return HomeStore(hue: hue, dyson: dyson, secrets: PreviewSecrets(), persistence: persistence)
    }
}

@MainActor private final class PreviewHue: HueClientProtocol {
    var snapshot = HueBridgeSnapshot(lights: [
        HueLight(id: "00000000-0000-4000-8000-000000000001", name: "Hue Lamp 2", isOn: true, brightness: 37, reachable: true, archetype: "table_shade"),
        HueLight(id: "00000000-0000-4000-8000-000000000002", name: "Hue Lamp 3", isOn: true, brightness: 60, reachable: true, archetype: "floor_shade"),
        HueLight(id: "00000000-0000-4000-8000-000000000003", name: "Hue Smart plug 1", isOn: true, brightness: nil, reachable: true, archetype: "plug"),
        HueLight(id: "00000000-0000-4000-8000-000000000004", name: "Hue Smart plug 2", isOn: false, brightness: nil, reachable: true, archetype: "plug")
    ], scenes: [
        HueScene(id: "00000000-0000-4000-8000-000000000011", name: "Arctic aurora", groupID: "room1", groupName: "Living room", active: "inactive", colors: [.xy(x: 0.19, y: 0.24)!, .xy(x: 0.21, y: 0.38)!, .xy(x: 0.27, y: 0.14)!]),
        HueScene(id: "00000000-0000-4000-8000-000000000012", name: "Spring blossom", groupID: "room1", groupName: "Living room", active: "inactive", colors: [.xy(x: 0.45, y: 0.24)!, .xy(x: 0.51, y: 0.31)!, .xy(x: 0.34, y: 0.22)!]),
        HueScene(id: "00000000-0000-4000-8000-000000000013", name: "Evening", groupID: "room1", groupName: "Living room", active: "static", colors: [.xy(x: 0.57, y: 0.4)!, .xy(x: 0.64, y: 0.33)!, .xy(x: 0.41, y: 0.2)!])
    ])
    func identify(host: String, bridgeID: String?) async throws -> HueConfiguration { throw ControlError.offline }
    func pair(configuration: HueConfiguration) async throws -> String { throw ControlError.offline }
    func fetchSnapshot(configuration: HueConfiguration, key: String) async throws -> HueBridgeSnapshot { snapshot }
    func watch(configuration: HueConfiguration, key: String, changed: @escaping @MainActor () async -> Void) async throws { try await Task.sleep(for: .seconds(86400)) }
    func setLight(configuration: HueConfiguration, key: String, id: String, on: Bool?, brightness: Double?) async throws {
        guard let index = snapshot.lights.firstIndex(where: { $0.id == id }) else { return }
        if let on { snapshot.lights[index].isOn = on }; if let brightness { snapshot.lights[index].brightness = brightness }
    }
    func recallScene(configuration: HueConfiguration, key: String, id: String) async throws {
        for index in snapshot.scenes.indices { snapshot.scenes[index].active = snapshot.scenes[index].id == id ? "static" : "inactive" }
        for index in snapshot.lights.indices where snapshot.lights[index].supportsBrightness { snapshot.lights[index].isOn = true }
    }
}
@MainActor private final class PreviewDyson: DysonClientProtocol {
    var onSnapshot: (@MainActor (DysonSnapshot) -> Void)?
    var onConnection: (@MainActor (ConnectionState, String?) -> Void)?
    var snapshot: DysonSnapshot = {
        var snapshot = DysonSnapshot(); snapshot.isOn = true; snapshot.autoMode = true; snapshot.speed = 1; snapshot.hasState = true
        snapshot.temperature = SensorReading(value: 22.4, receivedAt: Date()); snapshot.humidity = SensorReading(value: 46, receivedAt: Date())
        return snapshot
    }()
    func connect(configuration: DysonConfiguration, credential: String) async throws { onSnapshot?(snapshot); onConnection?(.online, nil) }
    func disconnect() { onConnection?(.offline, nil) }
    func requestSensors() {
        snapshot.temperature?.receivedAt = Date(); snapshot.humidity?.receivedAt = Date()
        snapshot.pm25?.receivedAt = Date(); snapshot.pm10?.receivedAt = Date(); snapshot.voc?.receivedAt = Date(); snapshot.nitrogenDioxide?.receivedAt = Date()
        onSnapshot?(snapshot)
    }
    func command(_ fields: [String: String]) throws {
        if let value = fields["fpwr"] { snapshot.isOn = value == "ON" }
        if let value = fields["auto"] { snapshot.autoMode = value == "ON" }
        if let value = fields["fnsp"] { snapshot.speed = Int(value) }
        onSnapshot?(snapshot)
    }
}
@MainActor private final class PreviewSecrets: SecretStoreProtocol {
    func read(_ account: String) throws -> String? { "preview-only" }
    func write(_ value: String, account: String) throws { }
    func delete(_ account: String) throws { }
}
@MainActor private final class PreviewConfiguration: ConfigurationStoreProtocol {
    var saved = SavedConfiguration()
    func load() throws -> SavedConfiguration { saved }
    func save(_ configuration: SavedConfiguration) throws { saved = configuration }
}
#endif
