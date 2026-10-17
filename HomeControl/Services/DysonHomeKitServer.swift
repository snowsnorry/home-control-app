import Foundation
import OSLog
@preconcurrency import HAP

enum DysonHomeCommand: Equatable, Sendable {
    case power(Bool)
    case automatic(Bool)
    case speed(Int)

    static func speed(percent: Double) throws -> Self {
        guard percent.isFinite, (0...100).contains(percent) else { throw HomeKitControlError.invalidValue }
        return percent == 0 ? .power(false) : .speed(max(1, Int((percent / 10).rounded())))
    }
    func fields() throws -> [String: String] {
        switch self {
        case .power(let on): return ["fpwr": on ? "ON" : "OFF"]
        case .automatic(let auto): return ["auto": auto ? "ON" : "OFF"]
        case .speed(let speed):
            guard (1...10).contains(speed) else { throw HomeKitControlError.invalidValue }
            return ["fpwr": "ON", "auto": "OFF", "fnsp": String(format: "%04d", speed)]
        }
    }
}

enum HomeKitControlError: Error, Sendable {
    case unavailable, invalidValue
}

struct DysonHomeKitStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case disabled = "Disabled"
        case starting = "Starting…"
        case advertising = "Checking visibility on the local network…"
        case waiting = "Waiting for fresh sensor data"
        case awaitingPairing = "Ready to add to Apple Home"
        case paired = "Paired with Apple Home"
        case failed = "Apple Home unavailable"
    }
    var state: State = .disabled
    var isPaired = false
    var setupCode: String?
    var setupURI: String?
    // Public HAP identity used to match our own Bonjour record; never logged.
    var discoveryIdentifier: String?
    var error: String?
    var readings: HomeKitAirReadings?
    var controlAvailable = false
}

@MainActor protocol HomeKitBonjourMonitoring: AnyObject {
    func start(identifier: String, completion: @escaping @MainActor (String?) -> Void)
    func stop()
}

/// A bound socket is not evidence of successful mDNS registration. Verify the exact accessory.
@MainActor final class HomeKitBonjourMonitor: NSObject, HomeKitBonjourMonitoring,
    @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let diagnosticLog = Logger(subsystem: "com.homecontrol.mac", category: "AppleHomeDiscovery")
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var identifier: String?
    private var completion: (@MainActor (String?) -> Void)?
    private var timeout: Task<Void, Never>?

    func start(identifier: String, completion: @escaping @MainActor (String?) -> Void) {
        stop()
        self.identifier = identifier; self.completion = completion
        let browser = NetServiceBrowser(); self.browser = browser
        browser.delegate = self
        diagnosticLog.notice("Starting HAP discovery; mainThread=\(Thread.isMainThread, privacy: .public)")
        browser.searchForServices(ofType: "_hap._tcp.", inDomain: "local.")
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.finish(error: "Bonjour did not discover this accessory within 10 seconds. This does not establish a permissions problem. Check visibility again to retry.")
        }
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        browser?.delegate = nil; browser?.stop(); browser = nil
        services.forEach { $0.stop() }; services = []
        identifier = nil; completion = nil
    }
    private func finish(error: String?) {
        let completion = completion
        stop()
        completion?(error)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser, identifier != nil else { return }
        services.append(service); service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        let domain = errorDict[NetService.errorDomain]?.intValue ?? 0
        diagnosticLog.error("Bonjour search failed; code=\(code, privacy: .public), domain=\(domain, privacy: .public)")
        finish(error: Self.searchFailure(code: code, domain: domain))
    }
    static func searchFailure(code: Int, domain: Int) -> String {
        // These errors describe the failed operation; they do not expose the user's permission toggle.
        String(format: String(localized: "Bonjour discovery failed (code: %lld, domain: %lld)."), code, domain)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services.contains(where: { $0 === sender }) else { return }
        let record = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        guard let identifier, record["id"] == Data(identifier.utf8), sender.port > 0,
              sender.addresses?.isEmpty == false else { return }
        finish(error: nil)
    }
}

/// A complete, validated set of values; no placeholder can reach the HAP server.
struct HomeKitAirReadings: Equatable, Sendable {
    var temperature: Double
    var humidity: Double
    var pm25: Double
    var pm10: Double
    var quality: UInt8

    static func validValue(_ reading: SensorReading?, range: ClosedRange<Double>, now: Date) -> Double? {
        guard let reading, now >= reading.receivedAt, reading.isFresh(at: now),
              let value = reading.value, value.isFinite, range.contains(value) else { return nil }
        return value
    }
    static func qualityValue(_ quality: AirQuality) -> UInt8 { UInt8(min(quality.rawValue + 1, 5)) }
    static func make(_ snapshot: DysonSnapshot, connected: Bool, now: Date) -> Self? {
        guard connected,
              let temperature = validValue(snapshot.temperature, range: 0...100, now: now),
              let humidity = validValue(snapshot.humidity, range: 0...100, now: now),
              let pm25 = validValue(snapshot.pm25, range: 0...1000, now: now),
              let pm10 = validValue(snapshot.pm10, range: 0...1000, now: now) else { return nil }
        var eligible = snapshot
        // Gas indices influence the shared quality scale but are not exported as densities.
        if validValue(snapshot.voc, range: 0...Double.greatestFiniteMagnitude, now: now) == nil { eligible.voc = nil }
        if validValue(snapshot.nitrogenDioxide, range: 0...Double.greatestFiniteMagnitude, now: now) == nil { eligible.nitrogenDioxide = nil }
        guard let quality = eligible.airQuality(at: now, connected: true) else { return nil }
        return Self(temperature: temperature, humidity: humidity, pm25: pm25, pm10: pm10,
                    quality: qualityValue(quality))
    }
}

/// Append services to preserve every existing temperature-service IID and the sensor category.
final class DysonHomeKitAccessory: HAP.Accessory.Thermometer, HAP.AccessoryDelegate {
    let humiditySensor = HAP.Service.HumiditySensor()
    // PM characteristic types define µg/m³. Omit Bouke/HAP's nonstandard unit token.
    let airQualitySensor = HAP.Service.AirQualitySensor(characteristics: [.pm25Density(unit: nil), .pm10Density(unit: nil)])
    let purifier = HAP.Service.AirPurifier(characteristics: [.rotationSpeed(minStep: 10)])
    private let control: (@Sendable (DysonHomeCommand) -> Void)?
    private var confirmedControl: DysonSnapshot?
    init(control: (@Sendable (DysonHomeCommand) -> Void)? = nil) {
        self.control = control
        super.init(info: HAP.Service.Info(name: "Dyson TP07", serialNumber: "homecontrol-temperature",
            manufacturer: "Home Control", model: "Dyson TP07"),
            additionalServices: [humiditySensor, airQualitySensor, purifier])
        reachable = false
        delegate = self
    }
    /// Upstream HAP accepts a write before invoking this delegate. Forward it to
    /// our command queue; later snapshots or reconciliation publish actual state.
    func characteristic<T>(_ characteristic: HAP.GenericCharacteristic<T>, ofService service: HAP.Service,
                           ofAccessory accessory: HAP.Accessory, didChangeValue value: T?) {
        guard accessory === self, service === purifier else { return }
        let command: DysonHomeCommand?
        if characteristic === purifier.active, let active = value as? HAP.Enums.Active {
            command = .power(active == .active)
        } else if characteristic === purifier.targetAirPurifierState, let mode = value as? HAP.Enums.TargetAirPurifierState {
            command = .automatic(mode == .auto)
        } else if characteristic === purifier.rotationSpeed, let speed = value as? Float {
            command = try? .speed(percent: Double(speed))
        } else { command = nil }
        guard reachable, let control, let command else {
            if let confirmedControl { applyControl(confirmedControl, connected: true) }
            return
        }
        control(command)
    }
    func applyControl(_ snapshot: DysonSnapshot, connected: Bool) {
        guard connected, snapshot.hasState else { return }
        confirmedControl = snapshot
        purifier.active.value = snapshot.isOn ? .active : .inactive
        purifier.targetAirPurifierState.value = snapshot.autoMode ? .auto : .manual
        // A missing manual setpoint in Auto is not evidence that the fan is idle.
        purifier.currentAirPurifierState.value = snapshot.isOn ? .purifyingAir : .inactive
        purifier.rotationSpeed?.value = snapshot.isOn ? Float((snapshot.speed ?? 0) * 10) : 0
    }
    func apply(_ values: HomeKitAirReadings) {
        temperatureSensor.currentTemperature.value = Float(values.temperature)
        humiditySensor.currentRelativeHumidity.value = Float(values.humidity)
        airQualitySensor.pm25Density?.value = Float(values.pm25)
        airQualitySensor.pm10Density?.value = Float(values.pm10)
        airQualitySensor.currentAirQuality.value = HAP.Enums.CurrentAirQuality(rawValue: values.quality)!
    }
}

@MainActor protocol DysonHomeKitServerProtocol: AnyObject {
    var onStatus: (@MainActor (DysonHomeKitStatus) -> Void)? { get set }
    var onControl: (@MainActor (DysonHomeCommand) async throws -> Void)? { get set }
    func start()
    func update(_ snapshot: DysonSnapshot, connected: Bool, now: Date)
    func stop()
    func reset()
}

/// Storage is synchronous because HAP must persist a pairing before completing its handshake.
protocol HomeKitSecretStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

struct HomeKitKeychainStorage: HomeKitSecretStorage {
    // Keep the original Keychain account so existing pairing keys remain accessible.
    private static let account = "homekit-temperature"
    func load() throws -> Data? {
        guard let value = try KeychainStore().read(Self.account) else { return nil }
        guard let data = Data(base64Encoded: value) else { throw HomeKitStorageError.invalidIdentity }
        return data
    }
    func save(_ data: Data) throws {
        try KeychainStore().write(data.base64EncodedString(), account: Self.account)
    }
    func delete() throws { try KeychainStore().delete(Self.account) }
}

enum HomeKitStorageError: Error { case invalidIdentity, missingConfiguration }

/// Buffer initialization so HAP's "use defaults on any read error" cannot overwrite existing keys.
final class HomeKitIdentityStorage: HAP.Storage, @unchecked Sendable {
    private let backing: any HomeKitSecretStorage
    private let lock = NSLock()
    private var data: Data
    private var armed = false
    var onFailure: (@Sendable () -> Void)?

    init(backing: any HomeKitSecretStorage) throws {
        self.backing = backing
        data = try backing.load() ?? Data()
    }
    func read() throws -> Data { lock.withLock { data } }
    func write(_ value: Data) throws {
        do {
            try lock.withLock {
                if armed { try backing.save(value) }
                data = value
            }
        } catch {
            onFailure?()
            throw HomeKitStorageError.missingConfiguration
        }
    }
    func prepareDevice(control: (@Sendable (DysonHomeCommand) -> Void)? = nil) throws -> (HAP.Device, DysonHomeKitAccessory) {
        let original = try read()
        // Preserve serial, existing service order, and keys when expanding the service graph.
        let accessory = DysonHomeKitAccessory(control: control)
        let device = HAP.Device(storage: self, accessory: accessory)
        let updated = try read()
        if !original.isEmpty {
            let keys = ["identifier", "privateKey", "setupCode", "setupKey", "pairings"]
            guard let before = try JSONSerialization.jsonObject(with: original) as? NSDictionary,
                  let after = try JSONSerialization.jsonObject(with: updated) as? NSDictionary,
                  keys.allSatisfy({ key in
                      guard let a = before[key] as? NSObject, let b = after[key] as? NSObject else { return false }
                      return a.isEqual(b)
                  }) else { throw HomeKitStorageError.invalidIdentity }
        }
        guard !updated.isEmpty else { throw HomeKitStorageError.missingConfiguration }
        try backing.save(updated)
        lock.withLock { armed = true }
        return (device, accessory)
    }
}

/// The worker owns server lifecycle and Bonjour. Characteristic reads, writes and
/// publication run on main; socket startup/shutdown never block the UI.
private final class DysonHomeKitWorker: NSObject, HAP.DeviceDelegate, @unchecked Sendable {
    enum Command { case start(UUID), update(DysonSnapshot, Bool, Date, UUID), stop, reset, report, reconcile(UUID) }
    private let commandsLock = NSLock()
    private var commands: [Command] = []
    private var thread: Thread?
    private var enabled = false
    private var device: HAP.Device?
    private var accessory: DysonHomeKitAccessory?
    private var server: HAP.Server?
    private var needsDeviceRefresh = false
    private var storage: HomeKitIdentityStorage?
    private var snapshot: DysonSnapshot?
    private var connected = false
    private var sourceNow: Date?
    private var wallAnchor: Date?
    private var values: HomeKitAirReadings?
    private var publishedSnapshot: DysonSnapshot?
    private var publishedConnected = false
    private var discoveryIdentifier: String?
    private var storageFailed = false
    private let backing: any HomeKitSecretStorage
    private let emit: @Sendable (DysonHomeKitStatus) -> Void
    private let control: @Sendable (DysonHomeCommand, UUID) -> Void
    private var controlEpoch = UUID()

    init(backing: any HomeKitSecretStorage, control: @escaping @Sendable (DysonHomeCommand, UUID) -> Void, emit: @escaping @Sendable (DysonHomeKitStatus) -> Void) {
        self.backing = backing; self.control = control; self.emit = emit
    }
    func enqueue(_ command: Command) {
        commandsLock.withLock {
            // A failed or stopped server must not spawn a new thread for every sensor tick.
            if case .update = command, thread == nil { return }
            commands.append(command)
            if thread == nil {
                let thread = Thread { [self] in run() }
                thread.name = "HomeControl.AppleHome"
                self.thread = thread
                thread.start()
            }
        }
    }
    private func run() {
        // NetService schedules itself on this thread's run loop.
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        while true {
            let batch = commandsLock.withLock { let batch = commands; commands = []; return batch }
            for command in batch { handle(command) }
            if commandsLock.withLock({ storageFailed }) {
                commandsLock.withLock { storageFailed = false }
                fail("Apple Home pairing data could not be saved. Sharing has stopped; retry before adding the accessory.")
            }
            // Enforce expiry even if the UI/main actor is temporarily busy or the Mac slept.
            if enabled {
                do { try refreshPublication() }
                catch { fail("Apple Home could not start its local server. Disable and enable sharing to retry.") }
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            let finished = commandsLock.withLock { () -> Bool in
                guard !enabled, commands.isEmpty else { return false }
                thread = nil
                return true
            }
            if finished { port.invalidate(); return }
        }
    }
    private func handle(_ command: Command) {
        switch command {
        case .start(let epoch):
            guard !enabled else { return }
            controlEpoch = epoch
            enabled = true
            emit(DysonHomeKitStatus(state: .starting))
            do {
                let storage = try HomeKitIdentityStorage(backing: backing)
                let (device, accessory) = try storage.prepareDevice(control: controlHandler())
                storage.onFailure = { [weak self] in
                    self?.commandsLock.withLock { self?.storageFailed = true }
                }
                self.storage = storage; self.device = device; self.accessory = accessory
                needsDeviceRefresh = false
                let configuration = try JSONSerialization.jsonObject(with: storage.read()) as? [String: Any]
                guard let identifier = configuration?["identifier"] as? String else { throw HomeKitStorageError.invalidIdentity }
                discoveryIdentifier = identifier
                device.delegate = self
                try publishIfFresh()
                report()
            } catch { fail("Apple Home pairing data could not be loaded or saved. Retry, or reset pairing explicitly.") }
        case .update(let snapshot, let connected, let now, let epoch):
            let epochChanged = controlEpoch != epoch
            controlEpoch = epoch
            self.snapshot = snapshot; self.connected = connected
            sourceNow = now; wallAnchor = Date()
            guard enabled, device != nil else { return }
            if epochChanged { pauseServer(); needsDeviceRefresh = true }
            do { try refreshPublication(force: epochChanged) }
            catch { fail("Apple Home could not start its local server. Disable and enable sharing to retry.") }
        case .stop:
            enabled = false; pauseServer(); snapshot = nil; publishedSnapshot = nil; values = nil; sourceNow = nil; wallAnchor = nil
            device = nil; accessory = nil; storage = nil
            emit(DysonHomeKitStatus())
        case .reconcile(let epoch):
            guard enabled, controlEpoch == epoch else { return }
            // Restore the latest Dyson state even if no new sensor values arrived.
            do { try refreshPublication(force: true) }
            catch { fail("Apple Home could not start its local server. Disable and enable sharing to retry.") }
        case .report:
            report()
        case .reset:
            enabled = false; pauseServer(); snapshot = nil; publishedSnapshot = nil; values = nil; sourceNow = nil; wallAnchor = nil
            device = nil; accessory = nil; storage = nil
            do { try backing.delete(); emit(DysonHomeKitStatus()) }
            catch { fail("Apple Home pairing data could not be removed. Retry resetting pairing.") }
        }
        if commandsLock.withLock({ storageFailed }) {
            commandsLock.withLock { storageFailed = false }
            fail("Apple Home pairing data could not be saved. Sharing has stopped; retry before adding the accessory.")
        }
    }
    private func controlHandler() -> @Sendable (DysonHomeCommand) -> Void {
        let epoch = controlEpoch, send = control
        return { command in send(command, epoch) }
    }
    private func refreshPublication(force: Bool = false) throws {
        guard let snapshot, let sourceNow, let wallAnchor else { return }
        // Translate the injected clock into wall-clock elapsed time, including sleep.
        let now = sourceNow.addingTimeInterval(max(0, Date().timeIntervalSince(wallAnchor)))
        let fresh = HomeKitAirReadings.make(snapshot, connected: connected, now: now)
        guard force || fresh != values || snapshot != publishedSnapshot || connected != publishedConnected else { return }
        values = fresh; publishedSnapshot = snapshot; publishedConnected = connected
        try publishIfFresh()
        report()
    }
    private func publishIfFresh() throws {
        guard let snapshot, let values, connected else { pauseServer(); return }
        if server == nil, needsDeviceRefresh {
            // HAP.stop() does not detach Device.server. Bonjour callbacks or clients may
            // retain the stopped Server, so reuse can trap in the next Server.init.
            // Rebuild the object graph from saved keys, preserving the accessory identity.
            guard let storage else { throw HomeKitStorageError.missingConfiguration }
            let (replacement, replacementAccessory) = try storage.prepareDevice(control: controlHandler())
            device?.delegate = nil
            replacement.delegate = self
            device = replacement; accessory = replacementAccessory
            needsDeviceRefresh = false
        }
        guard let accessory, let device else { throw HomeKitStorageError.missingConfiguration }
        DispatchQueue.main.sync {
            accessory.reachable = true
            accessory.apply(values)
            accessory.applyControl(snapshot, connected: connected)
        }
        if server == nil { server = try HAP.Server(device: device) }
    }
    private func pauseServer() {
        DispatchQueue.main.sync { accessory?.reachable = false }
        guard let server else { return }
        try? server.stop()
        self.server = nil
        needsDeviceRefresh = true
    }
    private func report() {
        guard enabled, let device else { return }
        emit(DysonHomeKitStatus(
            state: server == nil ? .waiting : (device.isPaired ? .paired : .awaitingPairing),
            isPaired: device.isPaired, setupCode: device.isPaired ? nil : device.setupCode,
            setupURI: device.isPaired ? nil : device.setupURI, discoveryIdentifier: discoveryIdentifier,
            readings: server == nil ? nil : values,
            controlAvailable: server != nil && connected && snapshot?.hasState == true))
    }
    private func fail(_ message: String) {
        enabled = false; pauseServer()
        snapshot = nil; publishedSnapshot = nil; values = nil; sourceNow = nil; wallAnchor = nil; connected = false
        device = nil; accessory = nil; storage = nil
        emit(DysonHomeKitStatus(state: .failed, error: message))
    }
    func didChangePairingState(from: HAP.PairingState, to: HAP.PairingState) {
        // HAP can call this from a request thread; serialize reporting with lifecycle commands.
        enqueue(.report)
    }
}

@MainActor final class DysonHomeKitServer: DysonHomeKitServerProtocol {
    var onStatus: (@MainActor (DysonHomeKitStatus) -> Void)?
    private let backing: any HomeKitSecretStorage
    private let discovery: any HomeKitBonjourMonitoring
    private var requestedEnabled = false
    private var sourceAvailable = false
    private var workerStatus = DysonHomeKitStatus()
    private var checkingIdentifier: String?
    private var verifiedIdentifier: String?
    private var discoveryError: String?
    var onControl: (@MainActor (DysonHomeCommand) async throws -> Void)?
    private var controlTasks: [UUID: Task<Void, Never>] = [:]
    private var controlEpoch = UUID()
    private lazy var worker = DysonHomeKitWorker(backing: backing, control: { [weak self] command, epoch in
        DispatchQueue.main.async {
            self?.perform(command, epoch: epoch)
        }
    }) { [weak self] status in
        // A FIFO main-queue delivery preserves the worker's lifecycle ordering.
        DispatchQueue.main.async { self?.receive(status) }
    }
    init(backing: any HomeKitSecretStorage = HomeKitKeychainStorage(),
         discovery: any HomeKitBonjourMonitoring = HomeKitBonjourMonitor()) {
        self.backing = backing; self.discovery = discovery
    }
    func start() { requestedEnabled = true; worker.enqueue(.start(controlEpoch)) }
    func update(_ snapshot: DysonSnapshot, connected: Bool, now: Date) {
        let available = snapshot.hasState && HomeKitAirReadings.make(snapshot, connected: connected, now: now) != nil
        if sourceAvailable, !available { cancelControls() }
        sourceAvailable = available
        worker.enqueue(.update(snapshot, connected, now, controlEpoch))
    }
    func stop() { requestedEnabled = false; sourceAvailable = false; cancelControls(); clearDiscovery(); worker.enqueue(.stop) }
    func reset() { requestedEnabled = false; sourceAvailable = false; cancelControls(); clearDiscovery(); worker.enqueue(.reset) }
    private func cancelControls() {
        controlEpoch = UUID()
        controlTasks.values.forEach { $0.cancel() }; controlTasks = [:]
    }
    private func perform(_ command: DysonHomeCommand, epoch expectedEpoch: UUID) {
        guard requestedEnabled, sourceAvailable, workerStatus.controlAvailable,
              controlEpoch == expectedEpoch, let onControl else {
            worker.enqueue(.reconcile(controlEpoch)); return
        }
        let id = UUID(), epoch = controlEpoch
        controlTasks[id] = Task { [weak self] in
            // Home already accepted the write. HomeStore retains confirmation,
            // timeout reporting and cancellation; reconcile Home after either outcome.
            do { try await onControl(command) } catch { }
            guard let self, self.controlEpoch == epoch else { return }
            self.controlTasks[id] = nil
            self.worker.enqueue(.reconcile(epoch))
        }
    }
    private func clearDiscovery() {
        discovery.stop(); checkingIdentifier = nil; verifiedIdentifier = nil; discoveryError = nil
    }
    private func receive(_ status: DysonHomeKitStatus) {
        guard requestedEnabled || status.state == .disabled || status.state == .failed else { return }
        let lostControl = sourceAvailable && workerStatus.controlAvailable && !status.controlAvailable && status.state == .waiting
        workerStatus = status
        if status.state == .failed || lostControl { sourceAvailable = false; cancelControls() }
        guard status.state == .awaitingPairing || status.state == .paired else {
            clearDiscovery(); onStatus?(status); return
        }
        guard let identifier = status.discoveryIdentifier else {
            var failed = status; failed.state = .failed
            failed.error = "Apple Home pairing data could not be loaded or saved. Retry, or reset pairing explicitly."
            onStatus?(failed); return
        }
        if verifiedIdentifier == identifier { onStatus?(status); return }
        var pending = status
        pending.state = discoveryError == nil ? .advertising : .failed
        pending.error = discoveryError
        onStatus?(pending)
        guard checkingIdentifier != identifier else { return }
        checkingIdentifier = identifier
        discovery.start(identifier: identifier) { [weak self] error in
            guard let self, self.requestedEnabled, self.checkingIdentifier == identifier else { return }
            self.discoveryError = error
            if error == nil { self.verifiedIdentifier = identifier }
            self.receive(self.workerStatus)
        }
    }
    static func validTemperature(_ reading: SensorReading?, connected: Bool, now: Date) -> Double? {
        connected ? HomeKitAirReadings.validValue(reading, range: 0...100, now: now) : nil
    }
}
