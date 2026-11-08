#if DEBUG
import Foundation
import Observation

@MainActor @Observable final class DysonDiagnostic {
    var email = ""
    var country = Locale.current.region?.identifier ?? "CZ"
    var password = ""
    var code = ""
    var codeSent = false
    private(set) var sessionSavePending = false
    private(set) var signingIn = false
    private(set) var signInStatus = ""
    private(set) var devices: [CloudDysonDevice] = []
    var selectedSerial = ""
    var host = ""
    private(set) var readingHistory = false
    private(set) var historyStatus = ""
    private(set) var capturing = false
    private(set) var liveStatus = ""
    private(set) var latestState = ""
    private(set) var packetCount = 0
    var selectedDevice: CloudDysonDevice? { devices.first { $0.serial == selectedSerial } }
    var canRecordLive: Bool { selectedDevice != nil || saved != nil }
    let directory: URL

    private let saved = (try? FileConfigurationStore().load())?.dyson
    private let cloud = MyDysonClient()
    private let local = DysonClient()
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var packets: [[String: Any]] = []
    @ObservationIgnored private var captureURL: URL?

    init(directory: URL) {
        self.directory = directory
        host = saved?.host ?? ""
    }

    func requestCode() async {
        guard !signingIn else { return }
        signingIn = true
        defer { signingIn = false }
        sessionSavePending = false
        signInStatus = "Запрашиваю код…"
        codeSent = false
        do {
            try await cloud.requestCode(email: email, country: country)
            codeSent = true
            signInStatus = "Код отправлен на почту."
        } catch {
            signInStatus = error.localizedDescription
        }
    }

    func signIn() async {
        guard !signingIn else { return }
        signingIn = true
        defer {
            password = ""
            code = ""
            signingIn = false
        }
        signInStatus = "Вхожу в MyDyson…"
        do {
            let session = try await cloud.verify(code: code.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            sessionSavePending = false
            guard let first = session.devices.first else {
                signInStatus = "В аккаунте нет совместимого TP07."
                return
            }
            token = session.token
            devices = session.devices
            selectedSerial = devices.first { $0.serial == saved?.serial }?.serial ?? first.serial
            fillHost()
            signInStatus = "Вход выполнен."
            await readHistory()
        } catch {
            sessionSavePending = error is MyDysonSessionSaveError
            signInStatus = error.localizedDescription
        }
    }

    func fillHost() {
        host = selectedSerial == saved?.serial ? saved?.host ?? "" : ""
    }

    func readHistory() async {
        guard !readingHistory, let device = selectedDevice, !token.isEmpty else { return }
        readingHistory = true
        defer { readingHistory = false }
        historyStatus = "Запрашиваю историю…"
        let redactions = identifiers(for: device)
        var results: [String] = []
        for hourly in [false, true] {
            let label = hourly ? "Почасовая история" : "История с шагом 15 минут"
            do {
                let data = try await cloud.requestDiagnosticHistory(serial: device.serial, token: token, hourly: hourly)
                let response = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                try write(
                    ["receivedAt": Date().ISO8601Format(), "response": Self.redacted(response, replacing: redactions)],
                    to: newFile(hourly ? "history-hourly" : "history-15min")
                )
                results.append("\(label): сохранена.")
            } catch {
                results.append("\(label): \(error.localizedDescription)")
            }
            historyStatus = results.joined(separator: "\n")
        }
    }

    func startLive() {
        guard !capturing else { return }
        let configuration: DysonConfiguration
        let credential: String
        var redactions: [String]
        do {
            let address = try validatedHost(host)
            if let device = selectedDevice {
                configuration = DysonConfiguration(
                    host: address, serial: device.serial,
                    topicPrefix: device.serial == saved?.serial ? saved?.topicPrefix ?? device.topicPrefix : device.topicPrefix,
                    name: device.name
                )
                credential = device.credential
                redactions = identifiers(for: device)
            } else {
                guard var saved, let key = try KeychainStore().read("dyson"), !key.isEmpty else {
                    throw ControlError.message("В Home Control нет сохранённого подключения к Dyson.")
                }
                saved.host = address
                configuration = saved
                credential = key
                redactions = [saved.serial, saved.name, address, key]
            }
        } catch {
            liveStatus = error.localizedDescription
            return
        }
        let identifiers = redactions.filter { !$0.isEmpty }
        let url = newFile("live-mqtt")
        packets = []
        packetCount = 0
        latestState = ""
        captureURL = url
        do {
            try writeCapture()
        } catch {
            liveStatus = "Не удалось создать отчёт. \(error.localizedDescription)"
            return
        }
        capturing = true
        liveStatus = "Подключаюсь к TP07…"
        local.onDiagnosticMessage = { [weak self] data in
            self?.record(data, redactions: identifiers)
        }
        local.onConnection = { [weak self] state, _ in
            guard state == .offline, let self, packetCount > 0 else { return }
            stopLive(message: "Соединение потеряно. Сохранено пакетов: \(packetCount).")
        }
        liveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await local.connect(configuration: configuration, credential: credential)
                try Task.checkCancellation()
                liveStatus = "Записываю сообщения TP07 в течение 3 минут…"
                for index in 1...36 {
                    try await Task.sleep(for: .seconds(5))
                    local.requestState()
                    if index.isMultiple(of: 2) { local.requestSensors() }
                }
                // Give the final requests time to arrive before disconnecting.
                try await Task.sleep(for: .seconds(2))
                stopLive()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                stopLive(message: "Локальная запись прервана. \(error.localizedDescription)")
            }
        }
    }

    func stopLive(message: String? = nil) {
        guard capturing else { return }
        capturing = false
        liveTask?.cancel()
        liveTask = nil
        local.onDiagnosticMessage = nil
        local.onConnection = nil
        local.disconnect()
        liveStatus = message ?? "Запись завершена. Пакетов: \(packetCount)."
    }

    private func record(_ data: Data, redactions: [String]) {
        guard let packet = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = packet["msg"] as? String else { return }
        // Only capture device telemetry. Configuration replies can contain network credentials.
        let allowed = ["CURRENT-STATE", "CURRENT-PRODUCT-STATE", "STATE-CHANGE",
                       "ENVIRONMENTAL-CURRENT-SENSOR-DATA", "ENVIRONMENTAL-AND-USAGE-DATA"]
        guard allowed.contains(kind) else { return }
        if let state = packet["product-state"] as? [String: Any] {
            latestState = ["fpwr", "auto", "fnsp", "fnst"].compactMap { key in
                DysonCodec.string(state[key]).map { "\(key)=\($0)" }
            }.joined(separator: "   ")
        }
        packets.append(["receivedAt": Date().ISO8601Format(), "packet": Self.redacted(packet, replacing: redactions)])
        do {
            try writeCapture()
            packetCount = packets.count
        } catch {
            stopLive(message: "Не удалось сохранить пакет. \(error.localizedDescription)")
        }
    }

    private func identifiers(for device: CloudDysonDevice) -> [String] {
        [email.trimmingCharacters(in: .whitespacesAndNewlines), device.serial, device.name, device.credential, token,
         host.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
    }

    private func newFile(_ name: String) -> URL {
        let time = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "\(name)-\(time).json")
    }

    private func writeCapture() throws {
        guard let captureURL else { return }
        try write(packets, to: captureURL)
    }

    private func write(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func redacted(_ value: Any, replacing identifiers: [String]) -> Any {
        func clean(_ text: String) -> String {
            identifiers.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]", options: .caseInsensitive) }
        }
        switch value {
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, field) in object {
                let lower = key.lowercased()
                let privateKey = ["password", "credential", "token", "serial", "email", "account", "ssid", "address", "location", "postcode"]
                    .contains { lower.contains($0) }
                result[clean(key)] = privateKey ? "[redacted]" : redacted(field, replacing: identifiers)
            }
            return result
        case let array as [Any]:
            return array.map { redacted($0, replacing: identifiers) }
        case let text as String:
            return clean(text)
        default:
            return value
        }
    }
}
#endif
