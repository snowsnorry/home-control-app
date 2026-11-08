import Foundation
import CommonCrypto
import OSLog

/// Isolated adapter for the unofficial MyDyson application API.
@MainActor final class MyDysonClient: CloudDysonClientProtocol, DysonHistoryClientProtocol {
    private static let logger = Logger(subsystem: "com.homecontrol.mac", category: "MyDyson")
    private let sessionConfiguration: URLSessionConfiguration
    private var session: URLSession
    private let sessions: MyDysonSessions
    private var verifiedSession: (token: String, devices: [CloudDysonDevice])?
    init(sessionConfiguration: URLSessionConfiguration = .ephemeral, secrets: any SecretStoreProtocol = KeychainStore()) {
        self.sessionConfiguration = sessionConfiguration
        self.session = URLSession(configuration: sessionConfiguration)
        self.sessions = MyDysonSessions(secrets: secrets)
    }
    private var email = ""
    private var country = ""
    private var challenge = ""
    private var generation = UUID()
    private let host = "https://appapi.cp.dyson.com"
    private var authenticationQuery: [URLQueryItem] {
        [URLQueryItem(name: "country", value: country), URLQueryItem(name: "culture", value: "en-US")]
    }
    func reset() {
        generation = UUID()
        session.invalidateAndCancel(); session = URLSession(configuration: sessionConfiguration)
        email = ""; country = ""; challenge = ""
        verifiedSession = nil
    }
    private func request(_ path: String, method: String = "POST", body: [String: String]? = nil, query: [URLQueryItem] = [], token: String? = nil, logLabel: String? = nil) async throws -> Data {
        var url = URLComponents(string: host + path)!
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!); request.httpMethod = method; request.timeoutInterval = 20
        // Dyson can rate-limit verification requests made with the legacy "android client" identifier.
        request.setValue("DysonLink/205298 Darwin/27.0.0", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ControlError.offline }
        // Only endpoint and status: never log bodies, headers, email, or credentials.
        Self.logger.notice("API \(logLabel ?? path, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
        if logLabel != nil, !(200...299).contains(http.statusCode) {
            throw DysonHistoryHTTPError(status: http.statusCode)
        }
        if http.statusCode == 429 { throw ControlError.message(String(localized: "Too many requests. Wait before requesting another code.")) }
        if [400, 401, 403].contains(http.statusCode) { throw ControlError.authorization }
        guard (200...299).contains(http.statusCode) else { throw ControlError.message(String(localized: "MyDyson is unavailable. Try again later or use manual setup.")) }
        return data
    }
    func requestCode(email: String, country: String) async throws {
        reset()
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.country = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard self.email.contains("@"), self.country.count == 2, self.country != "CN" else {
            throw ControlError.message(String(localized: "Enter your account email and two-letter country code. Mainland China accounts are not supported."))
        }
        _ = try await request("/v1/provisioningservice/application/Android/version", method: "GET")
        let query = [URLQueryItem(name: "country", value: self.country)]
        let status = try await request("/v3/userregistration/email/userstatus", body: ["email": self.email], query: query)
        guard let object = try JSONSerialization.jsonObject(with: status) as? [String: Any], object["accountStatus"] as? String == "ACTIVE" else { throw ControlError.authorization }
        let data = try await request("/v3/userregistration/email/auth", body: ["email": self.email], query: authenticationQuery)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = result["challengeId"] as? String else { throw ControlError.authorization }
        challenge = id
    }
    func verify(code: String, password: String) async throws -> (token: String, devices: [CloudDysonDevice]) {
        let activeGeneration = generation
        if verifiedSession == nil {
            let token = try await verifyToken(code: code, password: password)
            let devices = try await devices(token: token)
            try Task.checkCancellation()
            guard generation == activeGeneration else { throw CancellationError() }
            verifiedSession = (token, devices)
        }
        guard let verifiedSession else { throw ControlError.authorization }
        try Task.checkCancellation()
        // Save at login, before device connection or a diagnostic process can end.
        // If Keychain fails, retain this result so retrying does not request another code.
        do {
            for device in verifiedSession.devices {
                try sessions.save(verifiedSession.token, for: device.serial)
            }
        } catch {
            throw MyDysonSessionSaveError()
        }
        reset()
        return verifiedSession
    }
    private func verifyToken(code: String, password: String) async throws -> String {
        guard !challenge.isEmpty else { throw ControlError.authorization }
        let data = try await request("/v3/userregistration/email/verify", body: ["email": email, "password": password, "challengeId": challenge, "otpCode": code], query: authenticationQuery)
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = auth["token"] as? String, !token.isEmpty else { throw ControlError.authorization }
        return token
    }
    private func devices(token: String) async throws -> [CloudDysonDevice] {
        let manifest = try await request("/v2/provisioningservice/manifest", method: "GET", token: token)
        return try Self.parseManifest(manifest)
    }
    func fetchHistory(serial: String, token: String) async throws -> DysonHistory {
        let data = try await requestHistory(serial: serial, token: token, endpoint: "environmentdata/daily")
        return try JSONDecoder().decode(DysonHistory.self, from: data)
    }
    #if DEBUG
    func requestDiagnosticHistory(serial: String, token: String, hourly: Bool) async throws -> Data {
        try await requestHistory(serial: serial, token: token, endpoint: hourly ? "environmentdailyhistory" : "environmentdata/daily")
    }
    #endif
    private func requestHistory(serial: String, token: String, endpoint: String) async throws -> Data {
        guard !serial.isEmpty, serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw ControlError.message(String(localized: "The Dyson serial number is invalid."))
        }
        return try await request("/v1/messageprocessor/devices/\(serial)/\(endpoint)", method: "GET", token: token, logLabel: endpoint)
    }
    static func parseManifest(_ data: Data) throws -> [CloudDysonDevice] {
        guard let devices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ControlError.message(String(localized: "MyDyson returned an unexpected device list.")) }
        return try devices.compactMap { device in
            let product = device["ProductType"] as? String ?? ""
            guard product.hasPrefix("438") || product == "TP07", let serial = device["Serial"] as? String,
                  let encrypted = device["LocalCredentials"] as? String else { return nil }
            var prefix = product == "TP07" ? "438" : product
            let version = device["Version"] as? String ?? ""
            let variant = device["variant"] as? String ?? (version.hasPrefix("438") ? String(version.dropFirst(3).prefix(1)) : "")
            if prefix == "438", ["E", "K", "M"].contains(variant.uppercased()) { prefix += variant.uppercased() }
            return CloudDysonDevice(serial: serial, name: device["Name"] as? String ?? "Dyson TP07", topicPrefix: prefix, credential: try decryptCredential(encrypted))
        }
    }
    static func decryptCredential(_ encoded: String) throws -> String {
        guard let encrypted = Data(base64Encoded: encoded), !encrypted.isEmpty else { throw ControlError.authorization }
        // Fixed MyDyson protocol key, shared by all accounts; not a user secret.
        let key = Array(UInt8(1)...UInt8(32)), iv = [UInt8](repeating: 0, count: 16)
        var output = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        var count = 0
        let status = encrypted.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBuffer in
                iv.withUnsafeBytes { ivBuffer in
                    output.withUnsafeMutableBytes { buffer in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBuffer.baseAddress, key.count, ivBuffer.baseAddress, input.baseAddress, encrypted.count, buffer.baseAddress, buffer.count, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess, let result = try JSONSerialization.jsonObject(with: Data(output.prefix(count))) as? [String: Any], let password = result["apPasswordHash"] as? String else { throw ControlError.authorization }
        return password
    }
}

struct DysonHistoryHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401: String(localized: "Dyson rejected the saved account session. Restore the MyDyson connection in Settings.")
        case 403, 404: String(localized: "MyDyson history is unavailable for this purifier. Check that it is linked to this account.")
        case 429: String(localized: "MyDyson is receiving too many requests. Try again later.")
        default: String(localized: "MyDyson could not load history (HTTP \(status)).")
        }
    }
}

struct MyDysonSessionSaveError: LocalizedError {
    var errorDescription: String? {
        String(localized: "MyDyson accepted your sign-in, but the session could not be saved in Keychain. Retry saving; no new code or password is needed.")
    }
}
