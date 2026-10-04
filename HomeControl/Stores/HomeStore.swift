import Foundation
import Observation

@MainActor @Observable final class HomeStore {
    private(set) var configuration = SavedConfiguration()
    private(set) var hueState: ConnectionState = .notConnected
    private(set) var dysonState: ConnectionState = .notConnected
    private(set) var lights: [HueLight] = []
    private(set) var scenes: [HueScene] = []
    private(set) var pendingSceneID: String?
    private(set) var dyson = DysonSnapshot()
    private(set) var now: Date
    var hueError: String?
    var dysonError: String?
    var storageError: String?
    private(set) var pendingLights: Set<String> = []
    private(set) var dysonPending = false
    @ObservationIgnored private let hue: any HueClientProtocol
    @ObservationIgnored private let dysonClient: any DysonClientProtocol
    @ObservationIgnored private let secrets: any SecretStoreProtocol
    @ObservationIgnored private let persistence: any ConfigurationStoreProtocol
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private var hueTask: Task<Void, Never>?
    @ObservationIgnored private var dysonTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var commandTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hueCommandIDs: Set<UUID> = []
    @ObservationIgnored private var hueGeneration = UUID()
    @ObservationIgnored private var dysonGeneration = UUID()
    @ObservationIgnored private var started = false

    init(hue: any HueClientProtocol = HueClient(), dyson: any DysonClientProtocol = DysonClient(),
         secrets: any SecretStoreProtocol = KeychainStore(), persistence: any ConfigurationStoreProtocol = FileConfigurationStore(), clock: any AppClock = SystemClock()) {
        self.hue = hue; self.dysonClient = dyson; self.secrets = secrets; self.persistence = persistence; self.clock = clock
        now = clock.now
        do { configuration = try persistence.load() } catch { storageError = error.localizedDescription }
        dyson.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            var merged = snapshot
            if merged.temperature == nil { merged.temperature = self.dyson.temperature }
            if merged.humidity == nil { merged.humidity = self.dyson.humidity }
            if merged.pm25 == nil { merged.pm25 = self.dyson.pm25 }
            if merged.pm10 == nil { merged.pm10 = self.dyson.pm10 }
            if merged.voc == nil { merged.voc = self.dyson.voc }
            if merged.nitrogenDioxide == nil { merged.nitrogenDioxide = self.dyson.nitrogenDioxide }
            self.dyson = merged
        }
        dyson.onConnection = { [weak self] state, error in
            self?.dysonState = state
            if let error { self?.dysonError = error }
        }
    }
    var visibleScenes: [HueScene] {
        let selected = Set(configuration.hue?.selectedSceneIDs ?? [])
        return scenes.filter { selected.contains($0.id) }
    }
    func setSceneVisible(_ id: String, visible: Bool) {
        guard var config = configuration.hue else { return }
        var selected = Set(config.selectedSceneIDs ?? [])
        if visible { selected.insert(id) } else { selected.remove(id) }
        config.selectedSceneIDs = selected.sorted()
        var updated = configuration; updated.hue = config
        do { try persistence.save(updated); configuration = updated; storageError = nil }
        catch { storageError = error.localizedDescription }
    }
    private func applyHue(_ snapshot: HueBridgeSnapshot) { lights = snapshot.lights; scenes = snapshot.scenes }
    private func refreshHue(_ config: HueConfiguration, key: String, generation: UUID) async throws {
        let snapshot = try await hue.fetchSnapshot(configuration: config, key: key)
        try Task.checkCancellation()
        guard hueGeneration == generation else { throw CancellationError() }
        applyHue(snapshot)
    }
    private func cancelHueCommands() {
        for id in hueCommandIDs { commandTasks[id]?.cancel(); commandTasks[id] = nil }
        hueCommandIDs = []; pendingLights = []; pendingSceneID = nil
    }
    var badge: String? {
        guard dysonState == .online, let reading = dyson.temperature, reading.isFresh(at: now), let value = reading.value else { return nil }
        return String(format: "%.0f°", value)
    }
    func start() {
        guard !started else { return }; started = true
        reconnect(.hue); reconnect(.dyson)
        timer = Task { [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.clock.sleep(seconds: 1) } catch { return }
                self.now = self.clock.now; seconds += 1
                if seconds % 30 == 0, self.dysonState == .online { self.dysonClient.requestSensors() }
            }
        }
    }
    func stop() {
        hueTask?.cancel(); dysonTask?.cancel(); timer?.cancel(); cancelCommands()
        dysonClient.disconnect(); started = false
    }
    private func cancelCommands() {
        commandTasks.values.forEach { $0.cancel() }; commandTasks = [:]
        pendingLights = []; pendingSceneID = nil; hueCommandIDs = []; dysonPending = false
    }
    func reconnect(_ kind: DeviceKind) {
        if kind == .hue {
            hueTask?.cancel(); hueGeneration = UUID(); cancelHueCommands()
            guard let config = configuration.hue else { hueState = .notConnected; return }
            let generation = hueGeneration
            hueTask = Task { [weak self] in
                guard let self else { return }
                var delay = 1.0
                while !Task.isCancelled, self.hueGeneration == generation {
                    self.hueState = .connecting
                    do {
                        guard let key = try self.secrets.read("hue"), !key.isEmpty else { throw ControlError.authorization }
                        try await self.refreshHue(config, key: key, generation: generation)
                        try Task.checkCancellation()
                        self.hueState = .online; self.hueError = nil; delay = 1
                        try await self.hue.watch(configuration: config, key: key) { [weak self] in
                            guard let self, self.hueGeneration == generation else { return }
                            do { try await self.refreshHue(config, key: key, generation: generation) }
                            catch { if self.hueGeneration == generation, !Task.isCancelled { self.hueError = error.localizedDescription } }
                        }
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled, self.hueGeneration == generation else { return }
                        self.hueError = error.localizedDescription
                        if case ControlError.authorization = error { self.hueState = .authorizationRequired; return }
                        self.hueState = .offline
                    }
                    do { try await self.clock.sleep(seconds: delay) } catch { return }
                    delay = min(60, delay * 2)
                }
            }
        } else {
            maintainDyson(alreadyConnected: false)
        }
    }
    private func maintainDyson(alreadyConnected: Bool) {
        dysonTask?.cancel(); dysonGeneration = UUID()
        if !alreadyConnected { dysonClient.disconnect() }
        guard let config = configuration.dyson else { dysonState = .notConnected; return }
        let generation = dysonGeneration
        dysonTask = Task { [weak self] in
            guard let self else { return }
            var delay = 1.0
            var reuseConnection = alreadyConnected
            while !Task.isCancelled, self.dysonGeneration == generation {
                do {
                    if !reuseConnection {
                        guard let key = try self.secrets.read("dyson"), !key.isEmpty else { throw ControlError.authorization }
                        try await self.dysonClient.connect(configuration: config, credential: key)
                    }
                    reuseConnection = false
                    self.dysonError = nil; delay = 1
                    while self.dysonState == .online { try await self.clock.sleep(seconds: 1) }
                    if self.dysonState == .authorizationRequired { return }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.dysonGeneration == generation else { return }
                    self.dysonError = error.localizedDescription
                    if case ControlError.authorization = error { self.dysonState = .authorizationRequired; return }
                    self.dysonState = .offline
                }
                do { try await self.clock.sleep(seconds: delay) } catch { return }
                delay = min(60, delay * 2)
            }
        }
    }

    func identifyHue(host: String, bridgeID: String?) async throws -> HueConfiguration { try await hue.identify(host: host, bridgeID: bridgeID) }
    func connectHue(_ config: HueConfiguration) async throws {
        let key = try await hue.pair(configuration: config)
        let snapshot = try await hue.fetchSnapshot(configuration: config, key: key)
        try Task.checkCancellation()
        var selectedConfig = config
        selectedConfig.selectedSceneIDs = configuration.hue?.bridgeID == config.bridgeID ? configuration.hue?.selectedSceneIDs : nil
        var updated = configuration; updated.hue = selectedConfig
        try commit(updated, account: "hue", secret: key)
        applyHue(snapshot); reconnect(.hue)
    }
    func connectDyson(_ config: DysonConfiguration, credential: String) async throws {
        guard !config.serial.isEmpty, !credential.isEmpty, ["438", "438E", "438K", "438M"].contains(config.topicPrefix),
              config.serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw ControlError.message(String(localized: "Enter a valid serial, MQTT credential and TP07 topic prefix (438, 438E, 438K or 438M)."))
        }
        var config = config; config.host = try validatedHost(config.host)
        dysonTask?.cancel(); dysonGeneration = UUID()
        do {
            try await dysonClient.connect(configuration: config, credential: credential)
            try Task.checkCancellation()
            var updated = configuration; updated.dyson = config
            try commit(updated, account: "dyson", secret: credential)
            maintainDyson(alreadyConnected: true)
        } catch { reconnect(.dyson); throw error }
    }
    private func commit(_ updated: SavedConfiguration, account: String, secret: String?) throws {
        let previousSecret = try secrets.read(account)
        if let secret { try secrets.write(secret, account: account) } else { try secrets.delete(account) }
        do { try persistence.save(updated); configuration = updated }
        catch {
            if let previousSecret { try? secrets.write(previousSecret, account: account) } else { try? secrets.delete(account) }
            throw error
        }
    }
    func remove(_ kind: DeviceKind) {
        do {
            var updated = configuration
            if kind == .hue { updated.hue = nil } else { updated.dyson = nil }
            try commit(updated, account: kind.rawValue, secret: nil)
            cancelCommands()
            if kind == .hue { lights = []; scenes = []; hueError = nil } else { dyson = DysonSnapshot(); dysonError = nil }
            reconnect(kind)
        } catch { storageError = error.localizedDescription }
    }
    func setLight(_ light: HueLight, on: Bool? = nil, brightness: Double? = nil) {
        guard hueState == .online, pendingSceneID == nil, light.reachable,
              !pendingLights.contains(light.id), let config = configuration.hue else { return }
        guard brightness == nil || (light.supportsBrightness && brightness!.isFinite) else { return }
        let brightness = brightness.map { min(100, max(1, $0)) }
        let on = brightness != nil ? true : on
        pendingLights.insert(light.id); hueError = nil
        let generation = hueGeneration, taskID = UUID()
        hueCommandIDs.insert(taskID)
        commandTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.hueGeneration == generation { self.pendingLights.remove(light.id) }
                self.hueCommandIDs.remove(taskID); self.commandTasks[taskID] = nil
            }
            do {
                guard let key = try self.secrets.read("hue") else { throw ControlError.authorization }
                try await withCommandDeadline { [self] in
                let deadline = self.clock.now.addingTimeInterval(10)
                try await self.hue.setLight(configuration: config, key: key, id: light.id, on: on, brightness: brightness)
                while self.clock.now < deadline {
                    try Task.checkCancellation()
                    guard self.hueGeneration == generation, self.hueState == .online else { throw ControlError.offline }
                    try await self.refreshHue(config, key: key, generation: generation)
                    if let current = self.lights.first(where: { $0.id == light.id }),
                       (on == nil || current.isOn == on), (brightness == nil || abs((current.brightness ?? -100) - brightness!) < 1) { return }
                    try await self.clock.sleep(seconds: 0.4)
                }
                throw ControlError.timeout
                }
            } catch is CancellationError { }
            catch { if self.hueGeneration == generation, !Task.isCancelled { self.hueError = error.localizedDescription } }
        }
    }
    func recallScene(_ scene: HueScene) {
        guard hueState == .online, pendingSceneID == nil, pendingLights.isEmpty,
              scenes.contains(where: { $0.id == scene.id }),
              visibleScenes.contains(where: { $0.id == scene.id }), let config = configuration.hue else { return }
        pendingSceneID = scene.id; hueError = nil
        let generation = hueGeneration, taskID = UUID()
        hueCommandIDs.insert(taskID)
        commandTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.hueGeneration == generation { self.pendingSceneID = nil }
                self.hueCommandIDs.remove(taskID); self.commandTasks[taskID] = nil
            }
            do {
                guard let key = try self.secrets.read("hue") else { throw ControlError.authorization }
                try await withCommandDeadline { [self] in
                    try await self.hue.recallScene(configuration: config, key: key, id: scene.id)
                    try Task.checkCancellation()
                    guard self.hueGeneration == generation, self.hueState == .online else { throw CancellationError() }
                    try await self.refreshHue(config, key: key, generation: generation)
                }
            } catch is CancellationError { }
            catch { if self.hueGeneration == generation, !Task.isCancelled { self.hueError = error.localizedDescription } }
        }
    }
    func setDyson(_ fields: [String: String]) {
        guard dysonState == .online, !dysonPending else { return }
        dysonPending = true; dysonError = nil
        let generation = dysonGeneration, taskID = UUID()
        commandTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { self.dysonPending = false; self.commandTasks[taskID] = nil }
            do {
                let deadline = self.clock.now.addingTimeInterval(10)
                try self.dysonClient.command(fields)
                while self.clock.now < deadline {
                    try Task.checkCancellation()
                    guard self.dysonGeneration == generation, self.dysonState == .online else { throw ControlError.offline }
                    let matches = fields.allSatisfy { key, value in
                        switch key {
                        case "fpwr": return self.dyson.isOn == (value == "ON")
                        case "auto": return self.dyson.autoMode == (value == "ON")
                        case "fnsp": return self.dyson.speed == Int(value)
                        case "rhtm": return self.dyson.continuousMonitoring == (value == "ON")
                        default: return false
                        }
                    }
                    if matches { return }
                    try await self.clock.sleep(seconds: 0.1)
                }
                throw ControlError.timeout
            } catch is CancellationError { }
            catch { self.dysonError = error.localizedDescription }
        }
    }
}
