import Foundation
import Observation

@MainActor @Observable final class ConnectionWizard {
    var showsGeneral = true
    var selected: DeviceKind = .hue
    var hueHost = ""
    var bridgeID: String?
    var identifiedHue: HueConfiguration?
    var manualDyson = false
    var host = ""
    var serial = ""
    var topicPrefix = "438M"
    var credential = ""
    var email = ""
    var country = "CZ"
    var password = ""
    var code = ""
    var codeSent = false
    private(set) var sessionSavePending = false
    private(set) var recoveringDysonAccount = false
    var devices: [CloudDysonDevice] = []
    var selectedCloudID: String?
    var error: String?
    var busy = false
    var active = false
    var success = false
    let discovery = BonjourDiscovery()
    @ObservationIgnored private let cloud: any CloudDysonClientProtocol
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recoverySerial: String?
    init(cloud: any CloudDysonClientProtocol = MyDysonClient()) { self.cloud = cloud }
    func begin(_ kind: DeviceKind) {
        cancel(); showsGeneral = false; selected = kind; active = true; discovery.start(kind: kind)
    }
    func cancel() {
        task?.cancel(); task = nil; discovery.stop(); cloud.reset()
        sessionSavePending = false
        recoveringDysonAccount = false
        recoverySerial = nil
        password = ""; code = ""; credential = ""; email = ""; devices = []; selectedCloudID = nil
        codeSent = false; busy = false; active = false; success = false; error = nil; identifiedHue = nil
        host = ""; serial = ""; hueHost = ""; bridgeID = nil
    }
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        task = Task { [weak self] in
            do { try await operation() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
            if !Task.isCancelled { self?.busy = false }
        }
    }
    func identify(store: HomeStore) {
        run { [self] in
            let result = try await store.identifyHue(host: hueHost, bridgeID: bridgeID)
            try Task.checkCancellation(); identifiedHue = result
        }
    }
    func reconnect(store: HomeStore) {
        let kind = selected
        let serial = store.configuration.dyson?.serial
        run { [self] in
            store.reconnect(kind)
            guard kind == .dyson, let serial else { return }
            try await store.dysonHistory.refreshAndWait()
            guard store.configuration.dyson?.serial == serial else { return }
            if store.dysonHistory.needsAccountConnection {
                // Restore the existing account without replacing the device or
                // making the user repeat local network setup.
                cancel()
                showsGeneral = false
                selected = .dyson
                manualDyson = false
                active = true
                recoveringDysonAccount = true
                recoverySerial = serial
            }
        }
    }
    func pair(store: HomeStore) {
        guard let identifiedHue else { return }
        run { [self] in try await store.connectHue(identifiedHue); try Task.checkCancellation(); discovery.stop(); active = false; success = true }
    }
    func requestCode() {
        run { [self] in
            sessionSavePending = false
            try await cloud.requestCode(email: email, country: country)
            try Task.checkCancellation()
            codeSent = true
        }
    }
    func verify(store: HomeStore? = nil) {
        run { [self] in
            defer { if !Task.isCancelled { password = ""; code = "" } }
            let result: (token: String, devices: [CloudDysonDevice])
            do {
                result = try await cloud.verify(code: code, password: password)
                try Task.checkCancellation()
                sessionSavePending = false
            } catch {
                try Task.checkCancellation()
                sessionSavePending = error is MyDysonSessionSaveError
                throw error
            }
            try Task.checkCancellation()
            codeSent = false
            if let recoverySerial {
                guard let store, store.configuration.dyson?.serial == recoverySerial else {
                    throw ControlError.message(String(localized: "The connected purifier changed. Cancel and try Reconnect again."))
                }
                guard result.devices.contains(where: { $0.serial == recoverySerial }) else {
                    throw ControlError.message(String(localized: "This MyDyson account does not contain the connected purifier. Use the account linked to this purifier."))
                }
                try await store.dysonHistory.refreshAndWait()
                guard store.configuration.dyson?.serial == recoverySerial else { throw CancellationError() }
                let historyError = store.dysonHistory.error
                cancel()
                success = historyError == nil
                return
            }
            guard !result.devices.isEmpty else { throw ControlError.message(String(localized: "No compatible TP07 was found. You can use manual setup.")) }
            devices = result.devices
            selectedCloudID = devices.first?.id
            discovery.start(kind: .dyson)
        }
    }
    func connectDyson(store: HomeStore) {
        run { [self] in
            let device = devices.first { $0.id == selectedCloudID }
            let config = DysonConfiguration(host: host, serial: device?.serial ?? serial.trimmingCharacters(in: .whitespacesAndNewlines), topicPrefix: device?.topicPrefix ?? topicPrefix, name: device?.name ?? "Dyson TP07")
            try await store.connectDyson(config, credential: device?.credential ?? credential.trimmingCharacters(in: .whitespacesAndNewlines))
            try Task.checkCancellation(); cancel(); success = true
        }
    }
}
