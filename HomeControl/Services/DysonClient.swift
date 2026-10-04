import Foundation
import OSLog
@preconcurrency import CocoaMQTT

@MainActor final class DysonClient: DysonClientProtocol {
    private static let logger = Logger(subsystem: "com.homecontrol.mac", category: "DysonMQTT")
    // Dyson's broker rejects identifiers over 23 bytes with CONNACK 2.
    static func makeClientID() -> String {
        "HC" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
    }
    static func connectionFailure(for ack: CocoaMQTTConnAck) -> (ConnectionState, ControlError) {
        switch ack {
        case .badUsernameOrPassword, .notAuthorized:
            return (.authorizationRequired, .message(String(localized: "Dyson rejected the local device credentials. Run MyDyson setup again or check the manual MQTT credential. Your account password is not used for this connection.")))
        case .identifierRejected:
            return (.offline, .message(String(localized: "Dyson rejected the MQTT client identifier (code 2).")))
        case .unacceptableProtocolVersion:
            return (.offline, .message(String(localized: "Dyson does not support this MQTT protocol version (code 1).")))
        default:
            return (.offline, .message(String(localized: "The Dyson MQTT service refused the connection. Try again later.")))
        }
    }
    var onSnapshot: (@MainActor (DysonSnapshot) -> Void)?
    var onConnection: (@MainActor (ConnectionState, String?) -> Void)?
    private var mqtt: CocoaMQTT?
    private var configuration: DysonConfiguration?
    private var snapshot = DysonSnapshot()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var subscribed = false
    func connect(configuration: DysonConfiguration, credential: String) async throws {
        disconnect(); self.configuration = configuration; snapshot = DysonSnapshot(); subscribed = false
        let generation = self.generation
        let mqtt = CocoaMQTT(clientID: Self.makeClientID(), host: configuration.host, port: 1883)
        mqtt.username = configuration.serial; mqtt.password = credential
        mqtt.keepAlive = 30; mqtt.cleanSession = true; mqtt.autoReconnect = false; mqtt.logLevel = .off
        mqtt.delegateQueue = .main
        mqtt.didConnectAck = { [weak self] _, ack in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                Self.logger.notice("Connection acknowledgment: \(ack.rawValue, privacy: .public)")
                if ack == .accept {
                    self.mqtt?.subscribe(configuration.topicPrefix + "/" + configuration.serial + "/status/current", qos: .qos1)
                } else {
                    let (state, error) = Self.connectionFailure(for: ack)
                    self.finish(.failure(error))
                    self.disconnect()
                    self.onConnection?(state, error.localizedDescription)
                }
            }
        }
        mqtt.didSubscribeTopics = { [weak self] _, _, failed in
            let didFail = !failed.isEmpty
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if didFail {
                    Self.logger.error("Status subscription rejected")
                    let error = ControlError.message(String(localized: "Dyson rejected the status subscription. Check the device topic prefix in setup."))
                    self.finish(.failure(error)); self.disconnect(); self.onConnection?(.offline, error.localizedDescription); return
                }
                Self.logger.notice("Status subscription accepted")
                self.subscribed = true
                self.requestState(); self.requestSensors()
            }
        }
        mqtt.didReceiveMessage = { [weak self] _, message, _ in
            let data = Data(message.payload)
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                do {
                    self.snapshot = try DysonCodec.updated(self.snapshot, payload: data, now: Date())
                    self.onSnapshot?(self.snapshot)
                    if self.snapshot.hasState {
                        if self.continuation != nil { Self.logger.notice("Initial device state received") }
                        self.finish(.success(())); self.onConnection?(.online, nil)
                    }
                } catch { /* Ignore malformed packets; they do not replace the last valid state. */ }
            }
        }
        mqtt.didDisconnect = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.subscribed = false; self.finish(.failure(ControlError.offline)); self.onConnection?(.offline, nil)
            }
        }
        self.mqtt = mqtt
        onConnection?(.connecting, nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.finish(.failure(ControlError.timeout)); self.disconnect(); self.onConnection?(.offline, ControlError.timeout.localizedDescription)
                }
                if !mqtt.connect(timeout: 10) { finish(.failure(ControlError.offline)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }; self?.disconnect()
            }
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
    func disconnect() {
        generation = UUID(); subscribed = false
        finish(.failure(CancellationError()))
        mqtt?.didDisconnect = { _, _ in }; mqtt?.disconnect(); mqtt = nil
    }
    private func publish(message: String) {
        guard subscribed, let mqtt, let configuration, let text = try? DysonCodec.encode(message: message, now: Date()) else { return }
        mqtt.publish(configuration.topicPrefix + "/" + configuration.serial + "/command", withString: text, qos: .qos0, retained: false)
    }
    func requestState() { publish(message: "REQUEST-CURRENT-STATE") }
    func requestSensors() { publish(message: "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA") }
    func command(_ fields: [String: String]) throws {
        guard subscribed, let mqtt, let configuration else { throw ControlError.offline }
        let text = try DysonCodec.command(fields: fields, now: Date())
        mqtt.publish(configuration.topicPrefix + "/" + configuration.serial + "/command", withString: text, qos: .qos1, retained: false)
        requestState()
    }
}
