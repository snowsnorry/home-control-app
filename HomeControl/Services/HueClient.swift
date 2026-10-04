import Foundation
import Security

/// Trust is restricted to Hue CAs and the selected bridge, never a blanket TLS exception.
final class HueTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedID: String?
    private let anchors: [SecCertificate]
    private let lock = NSLock()
    private var verifiedID: String?
    var certificateID: String? { lock.withLock { verifiedID } }
    init(bridgeID: String?, rootCertificates: [SecCertificate]) {
        expectedID = bridgeID?.lowercased()
        anchors = rootCertificates
        super.init()
    }
    convenience init(bridgeID: String?) throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "HueRootCA", withExtension: "pem") else {
            throw ControlError.message(String(localized: "Hue certificates are missing from the app bundle."))
        }
        let pem = try String(contentsOf: url, encoding: .utf8)
        let anchors: [SecCertificate] = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").compactMap { part in
            guard let body = part.components(separatedBy: "-----END CERTIFICATE-----").first,
                  let data = Data(base64Encoded: body.filter { !$0.isWhitespace }),
                  !data.isEmpty else { return nil }
            return SecCertificateCreateWithData(nil, data as CFData)
        }
        self.init(bridgeID: bridgeID, rootCertificates: anchors)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        var commonName: CFString?
        SecCertificateCopyCommonName(leaf, &commonName)
        let identity = (commonName as String?)?.lowercased() ?? ""
        guard identity.count == 16, identity.allSatisfy({ $0.isHexDigit }), expectedID == nil || expectedID == identity else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Hue certificates identify the bridge by its ID rather than its LAN IP.
        // Validate chain/expiry, then independently enforce that exact bridge identity.
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        lock.withLock { verifiedID = identity }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class HueClient: HueClientProtocol {
    private let sessionConfiguration: URLSessionConfiguration?
    init(sessionConfiguration: URLSessionConfiguration? = nil) { self.sessionConfiguration = sessionConfiguration }
    private func session(_ configuration: HueConfiguration?) throws -> (URLSession, HueTrustDelegate) {
        let delegate = try HueTrustDelegate(bridgeID: configuration?.bridgeID)
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 86400
        return (URLSession(configuration: config, delegate: delegate, delegateQueue: nil), delegate)
    }
    private func request(host: String, path: String, key: String? = nil, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var components = URLComponents(); components.scheme = "https"; components.host = try validatedHost(host); components.path = path
        guard let url = components.url else { throw ControlError.message(String(localized: "Invalid bridge address.")) }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "hue-application-key")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: session.delegate as? HueTrustDelegate)
        guard let http = response as? HTTPURLResponse else { throw ControlError.offline }
        if http.statusCode == 401 || http.statusCode == 403 { throw ControlError.authorization }
        if http.statusCode == 404 { throw ControlError.incompatibleBridge }
        guard (200...299).contains(http.statusCode) else { throw ControlError.message(String(localized: "Hue request failed.") + " HTTP \(http.statusCode)") }
        return data
    }
    func identify(host: String, bridgeID: String?) async throws -> HueConfiguration {
        let host = try validatedHost(host)
        let selected = bridgeID.map { HueConfiguration(host: host, bridgeID: $0) }
        let (session, trust) = try session(selected); defer { session.invalidateAndCancel() }
        let bytes = try await data(request(host: host, path: "/api/config"), session: session)
        guard let config = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let id = config["bridgeid"] as? String, trust.certificateID == id.lowercased() else {
            throw ControlError.message(String(localized: "The bridge identity could not be verified."))
        }
        guard config["modelid"] as? String != "BSB001" else { throw ControlError.incompatibleBridge }
        return HueConfiguration(host: host, bridgeID: id.lowercased())
    }
    func pair(configuration: HueConfiguration) async throws -> String {
        let (session, _) = try session(configuration); defer { session.invalidateAndCancel() }
        let bytes = try await data(request(host: configuration.host, path: "/api", method: "POST", body: ["devicetype": "homecontrol#mac", "generateclientkey": true]), session: session)
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]], let first = result.first else { throw ControlError.authorization }
        if let error = first["error"] as? [String: Any] {
            if error["type"] as? Int == 101 { throw ControlError.message(String(localized: "Press the link button on your Hue Bridge, then try Connect again.")) }
            throw ControlError.authorization
        }
        guard let success = first["success"] as? [String: Any], let key = success["username"] as? String else { throw ControlError.authorization }
        return key
    }
    private static func resources(_ data: Data) throws -> [[String: Any]] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]],
              let resources = object["data"] as? [[String: Any]] else {
            throw ControlError.message(String(localized: "Malformed Hue response."))
        }
        guard errors.isEmpty else { throw ControlError.message(String(localized: "Hue could not complete the request.")) }
        return resources
    }
    static func parseResources(_ data: Data) throws -> [HueLight] { try parseSnapshot(data).lights }
    static func parseSnapshot(_ data: Data) throws -> HueBridgeSnapshot {
        let resources = try resources(data)
        let byID = Dictionary(resources.compactMap { r -> (String, [String: Any])? in
            guard let id = r["id"] as? String else { return nil }; return (id, r)
        }, uniquingKeysWith: { first, _ in first })
        var connectivity: [String: Bool] = [:]
        for r in resources where r["type"] as? String == "zigbee_connectivity" {
            if let id = (r["owner"] as? [String: Any])?["rid"] as? String { connectivity[id] = r["status"] as? String == "connected" }
        }
        let lights = resources.compactMap { r -> HueLight? in
            guard r["type"] as? String == "light", let id = r["id"] as? String else { return nil }
            let owner = (r["owner"] as? [String: Any])?["rid"] as? String ?? ""
            let device = byID[owner] ?? [:]
            let metadata = device["metadata"] as? [String: Any] ?? [:]
            let product = device["product_data"] as? [String: Any] ?? [:]
            let name = (r["metadata"] as? [String: Any])?["name"] as? String ?? metadata["name"] as? String ?? String(localized: "Hue light")
            let preferredArchetype = metadata["archetype"] as? String
            let archetype = preferredArchetype.flatMap { $0 == "unknown_archetype" ? nil : $0 } ?? product["product_archetype"] as? String ?? "unknown_archetype"
            return HueLight(id: id, name: name, isOn: (r["on"] as? [String: Any])?["on"] as? Bool ?? false,
                            brightness: (r["dimming"] as? [String: Any])?["brightness"] as? Double,
                            reachable: connectivity[owner] ?? true, archetype: archetype)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let scenes = resources.compactMap { r -> HueScene? in
            guard r["type"] as? String == "scene", let id = r["id"] as? String,
                  let name = (r["metadata"] as? [String: Any])?["name"] as? String,
                  let groupID = (r["group"] as? [String: Any])?["rid"] as? String else { return nil }
            let groupName = (byID[groupID]?["metadata"] as? [String: Any])?["name"] as? String ?? String(localized: "Other scenes")
            return HueScene(id: id, name: name, groupID: groupID, groupName: groupName,
                            active: (r["status"] as? [String: Any])?["active"] as? String,
                            colors: sceneColors(r))
        }.sorted {
            let groupOrder = $0.groupName.localizedStandardCompare($1.groupName)
            if groupOrder != .orderedSame { return groupOrder == .orderedAscending }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
        return HueBridgeSnapshot(lights: lights, scenes: scenes)
    }
    private static func sceneColors(_ resource: [String: Any]) -> [HueSceneColor] {
        func color(_ entry: [String: Any]) -> HueSceneColor? {
            if let xy = (entry["color"] as? [String: Any])?["xy"] as? [String: Any],
               let x = xy["x"] as? Double, let y = xy["y"] as? Double,
               let color = HueSceneColor.xy(x: x, y: y) { return color }
            if let mirek = (entry["color_temperature"] as? [String: Any])?["mirek"] as? Double {
                return HueSceneColor.temperature(mirek: mirek)
            }
            return nil
        }
        let palette = resource["palette"] as? [String: Any] ?? [:]
        let entries = (palette["color"] as? [[String: Any]] ?? [])
            + (palette["color_temperature"] as? [[String: Any]] ?? [])
        let colors = entries.compactMap(color)
        if !colors.isEmpty { return colors }
        // Static/custom scenes can have only per-light actions, without a palette.
        let actions = resource["actions"] as? [[String: Any]] ?? []
        var fallback: [HueSceneColor] = []
        for item in actions {
            guard let action = item["action"] as? [String: Any],
                  (action["on"] as? [String: Any])?["on"] as? Bool != false,
                  (action["dimming"] as? [String: Any])?["brightness"] as? Double != 0,
                  let value = color(action), !fallback.contains(value) else { continue }
            fallback.append(value)
        }
        return fallback
    }
    func fetchSnapshot(configuration: HueConfiguration, key: String) async throws -> HueBridgeSnapshot {
        let (session, _) = try session(configuration); defer { session.invalidateAndCancel() }
        return try Self.parseSnapshot(await data(request(host: configuration.host, path: "/clip/v2/resource", key: key), session: session))
    }
    static func sceneRecallBody(id: String) throws -> [String: Any] {
        guard UUID(uuidString: id) != nil else { throw ControlError.message(String(localized: "Invalid scene identifier.")) }
        return ["recall": ["action": "active"]]
    }
    func recallScene(configuration: HueConfiguration, key: String, id: String) async throws {
        let body = try Self.sceneRecallBody(id: id)
        let (session, _) = try session(configuration); defer { session.invalidateAndCancel() }
        let result = try await data(request(host: configuration.host, path: "/clip/v2/resource/scene/" + id, key: key, method: "PUT", body: body), session: session)
        _ = try Self.resources(result)
    }
    func setLight(configuration: HueConfiguration, key: String, id: String, on: Bool?, brightness: Double?) async throws {
        guard UUID(uuidString: id) != nil else { throw ControlError.message(String(localized: "Invalid light identifier.")) }
        var body: [String: Any] = [:]
        if let on { body["on"] = ["on": on] }
        if let brightness { body["dimming"] = ["brightness": min(100, max(0, brightness))] }
        let (session, _) = try session(configuration); defer { session.invalidateAndCancel() }
        let result = try await data(request(host: configuration.host, path: "/clip/v2/resource/light/" + id, key: key, method: "PUT", body: body), session: session)
        _ = try Self.parseResources(result)
    }
    func watch(configuration: HueConfiguration, key: String, changed: @escaping @MainActor () async -> Void) async throws {
        let (session, trust) = try session(configuration); defer { session.invalidateAndCancel() }
        var request = try request(host: configuration.host, path: "/eventstream/clip/v2", key: key)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90
        let (bytes, response) = try await session.bytes(for: request, delegate: trust)
        guard let response = response as? HTTPURLResponse else { throw ControlError.offline }
        if response.statusCode == 401 || response.statusCode == 403 { throw ControlError.authorization }
        guard response.statusCode == 200 else { throw ControlError.offline }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("data:") { await changed() }
        }
        throw ControlError.offline
    }
}
