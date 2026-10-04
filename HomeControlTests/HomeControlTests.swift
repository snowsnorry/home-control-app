import XCTest
import Security
@preconcurrency import CocoaMQTT
@testable import HomeControl

@MainActor final class DysonConnectionTests: XCTestCase {
    func testClientIDMeetsDysonBrokerLimit() {
        let ids = (0..<100).map { _ in DysonClient.makeClientID() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertTrue((1...23).contains(id.utf8.count))
            XCTAssertTrue(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
    }
    func testIdentifierAndProtocolRejectionsAreNotCredentialErrors() {
        let (state, error) = DysonClient.connectionFailure(for: .identifierRejected)
        XCTAssertEqual(state, .offline)
        XCTAssertTrue(error.localizedDescription.contains("identifier"))
        XCTAssertFalse(error.localizedDescription.contains("password"))
        XCTAssertEqual(DysonClient.connectionFailure(for: .unacceptableProtocolVersion).0, .offline)
        XCTAssertEqual(DysonClient.connectionFailure(for: .serverUnavailable).0, .offline)
    }
    func testActualCredentialRejectionExplainsLocalAuthentication() {
        for ack in [CocoaMQTTConnAck.badUsernameOrPassword, .notAuthorized] {
            let (state, error) = DysonClient.connectionFailure(for: ack)
            XCTAssertEqual(state, .authorizationRequired)
            XCTAssertTrue(error.localizedDescription.contains("local device credentials"))
        }
    }
}

final class CodecTests: XCTestCase {
    func packet(_ json: String) -> Data { Data(json.utf8) }
    func testTemperatureAndHumidity() throws {
        let now = Date(timeIntervalSince1970: 100)
        let result = try DysonCodec.updated(DysonSnapshot(), payload: packet(#"{"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"tact":"2962","hact":"0045"}}"#), now: now)
        XCTAssertEqual(result.temperature!.value!, 23.05, accuracy: 0.001)
        XCTAssertEqual(result.humidity?.value, 45)
        XCTAssertTrue(result.temperature!.isFresh(at: now.addingTimeInterval(119)))
        XCTAssertFalse(result.temperature!.isFresh(at: now.addingTimeInterval(120)))
    }
    func testPartialStateMergesAndChangeArrays() throws {
        var state = try DysonCodec.updated(DysonSnapshot(), payload: packet(#"{"msg":"CURRENT-STATE","product-state":{"fpwr":"ON","auto":"OFF","fnsp":"0005","rhtm":"ON"}}"#), now: Date())
        state = try DysonCodec.updated(state, payload: packet(#"{"msg":"STATE-CHANGE","product-state":{"auto":["OFF","ON"]}}"#), now: Date())
        XCTAssertTrue(state.isOn); XCTAssertTrue(state.autoMode); XCTAssertEqual(state.speed, 5); XCTAssertTrue(state.continuousMonitoring)
    }
    func testMissingSensorPreservesOtherReading() throws {
        var state = DysonSnapshot(); state.temperature = SensorReading(value: 20, receivedAt: Date())
        state = try DysonCodec.updated(state, payload: packet(#"{"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"hact":"0050"}}"#), now: Date())
        XCTAssertEqual(state.temperature?.value, 20); XCTAssertEqual(state.humidity?.value, 50)
    }
    func testSentinelsAreNotMeasurements() throws {
        for sentinel in ["OFF", "INIT", "FAIL", "NONE", "bad"] {
            let state = try DysonCodec.updated(DysonSnapshot(), payload: packet("{\"msg\":\"ENVIRONMENTAL-CURRENT-SENSOR-DATA\",\"data\":{\"tact\":\"\(sentinel)\",\"hact\":\"\(sentinel)\"}}"), now: Date())
            XCTAssertNil(state.temperature?.value); XCTAssertNil(state.humidity?.value)
        }
    }
    func testInvalidRangesAndMalformedPacket() throws {
        XCTAssertThrowsError(try DysonCodec.updated(DysonSnapshot(), payload: packet("no json"), now: Date()))
        let result = try DysonCodec.updated(DysonSnapshot(), payload: packet(#"{"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"tact":"9999","hact":"9999"}}"#), now: Date())
        XCTAssertNil(result.temperature?.value); XCTAssertNil(result.humidity?.value)
    }
    func testCommandWireFormat() throws {
        let string = try DysonCodec.command(fields: ["fpwr": "ON", "auto": "OFF", "fnsp": "0007"], now: Date(timeIntervalSince1970: 0))
        let object = try JSONSerialization.jsonObject(with: packet(string)) as! [String: Any]
        XCTAssertEqual(object["msg"] as? String, "STATE-SET")
        XCTAssertEqual((object["data"] as? [String: String])?["fnsp"], "0007")
        XCTAssertEqual(object["mode-reason"] as? String, "LAPP")
    }
    func testHostValidation() throws {
        XCTAssertEqual(try validatedHost(" 192.168.1.2 "), "192.168.1.2")
        XCTAssertEqual(try validatedHost("dyson.local"), "dyson.local")
        for invalid in ["", "https://evil.com", "host/path", "host@evil.com", "foo bar"] { XCTAssertThrowsError(try validatedHost(invalid)) }
    }
}

@MainActor final class HueParsingTests: XCTestCase {
    func testLightsAndConnectivity() throws {
        let data = Data(#"{"errors":[],"data":[{"id":"dev1","type":"device","metadata":{"name":"Desk"}},{"type":"zigbee_connectivity","owner":{"rid":"dev1"},"status":"disconnected"},{"id":"light1","type":"light","owner":{"rid":"dev1"},"on":{"on":true},"dimming":{"brightness":42.5}}]}"#.utf8)
        let result = try HueClient.parseResources(data)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].name, "Desk"); XCTAssertTrue(result[0].isOn)
        XCTAssertEqual(result[0].brightness, 42.5); XCTAssertFalse(result[0].reachable)
    }
    func testHTTP200WithHueErrorIsFailure() {
        XCTAssertThrowsError(try HueClient.parseResources(Data(#"{"errors":[{"description":"failed"}],"data":[]}"#.utf8)))
    }
    func testEmptyBridge() throws { XCTAssertEqual(try HueClient.parseResources(Data(#"{"errors":[],"data":[]}"#.utf8)), []) }
    func testBadCredentialCiphertext() { XCTAssertThrowsError(try MyDysonClient.decryptCredential("bad")) }
    func testUnsupportedDysonDevicesSkipped() throws {
        XCTAssertTrue(try MyDysonClient.parseManifest(Data(#"[{"Serial":"a","ProductType":"527","LocalCredentials":"x"}]"#.utf8)).isEmpty)
    }
}

@MainActor final class MemorySecrets: SecretStoreProtocol {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String? { values[account] }
    func write(_ value: String, account: String) throws { values[account] = value }
    func delete(_ account: String) throws { values[account] = nil }
}
@MainActor final class MemoryConfiguration: ConfigurationStoreProtocol {
    var saved = SavedConfiguration()
    var fail = false
    func load() throws -> SavedConfiguration { saved }
    func save(_ value: SavedConfiguration) throws { if fail { throw ControlError.message("test failure") }; saved = value }
}
@MainActor final class FakeClock: AppClock {
    var now = Date(timeIntervalSince1970: 0)
    func sleep(seconds: Double) async throws { now = now.addingTimeInterval(seconds); await Task.yield(); try Task.checkCancellation() }
}
@MainActor final class FakeHue: HueClientProtocol {
    var lights: [HueLight] = []
    var commands = 0
    var rejectPair = false
    func identify(host: String, bridgeID: String?) async throws -> HueConfiguration { HueConfiguration(host: host, bridgeID: bridgeID ?? "001788fffe123456") }
    func pair(configuration: HueConfiguration) async throws -> String { if rejectPair { throw ControlError.authorization }; return "hue-key" }
    func fetchLights(configuration: HueConfiguration, key: String) async throws -> [HueLight] { lights }
    func setLight(configuration: HueConfiguration, key: String, id: String, on: Bool?, brightness: Double?) async throws { commands += 1 }
    func watch(configuration: HueConfiguration, key: String, changed: @escaping @MainActor () async -> Void) async throws { try await Task.sleep(for: .seconds(1000)) }
}
@MainActor final class FakeDyson: DysonClientProtocol {
    var onSnapshot: (@MainActor (DysonSnapshot) -> Void)?
    var onConnection: (@MainActor (ConnectionState, String?) -> Void)?
    var commands: [[String: String]] = []
    var snapshot = DysonSnapshot()
    var confirm = true
    func connect(configuration: DysonConfiguration, credential: String) async throws { onSnapshot?(snapshot); onConnection?(.online, nil) }
    func disconnect() { onConnection?(.offline, nil) }
    func requestSensors() { }
    func command(_ fields: [String: String]) throws {
        commands.append(fields)
        if confirm {
            if let value = fields["fpwr"] { snapshot.isOn = value == "ON" }
            if let value = fields["auto"] { snapshot.autoMode = value == "ON" }
            if let value = fields["fnsp"] { snapshot.speed = Int(value) }
            onSnapshot?(snapshot)
        }
    }
}
@MainActor final class StoreTests: XCTestCase {
    func fixture() -> (HomeStore, FakeHue, FakeDyson, MemorySecrets, MemoryConfiguration, FakeClock) {
        let hue = FakeHue(), dyson = FakeDyson(), secrets = MemorySecrets(), config = MemoryConfiguration(), clock = FakeClock()
        let store = HomeStore(hue: hue, dyson: dyson, secrets: secrets, persistence: config, clock: clock)
        return (store, hue, dyson, secrets, config, clock)
    }
    func testFirstLaunchHasPlaceholdersAndNoBadge() {
        let (store, _, _, _, _, _) = fixture()
        XCTAssertNil(store.configuration.hue); XCTAssertNil(store.configuration.dyson); XCTAssertNil(store.badge)
        XCTAssertEqual(store.hueState, .notConnected); XCTAssertEqual(store.dysonState, .notConnected)
    }
    func testPairingPersistsOnlyAfterSuccessfulValidation() async throws {
        let (store, hue, _, secrets, config, _) = fixture()
        let bridge = HueConfiguration(host: "hue.local", bridgeID: "001788fffe123456")
        hue.rejectPair = true
        do { try await store.connectHue(bridge); XCTFail() } catch { }
        XCTAssertNil(config.saved.hue); XCTAssertNil(secrets.values["hue"])
        hue.rejectPair = false
        try await store.connectHue(bridge)
        XCTAssertEqual(config.saved.hue, bridge); XCTAssertEqual(secrets.values["hue"], "hue-key")
        store.stop()
    }
    func testFailedSaveRollsBackKeychain() async throws {
        let (store, _, _, secrets, config, _) = fixture()
        secrets.values["hue"] = "old-key"; config.fail = true
        do { try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "a")); XCTFail() } catch { }
        XCTAssertEqual(secrets.values["hue"], "old-key"); XCTAssertNil(store.configuration.hue)
    }
    func testRemovalDoesNotSendPowerCommand() async throws {
        let (store, _, dyson, secrets, config, _) = fixture()
        try await store.connectDyson(DysonConfiguration(host: "dyson.local", serial: "ABC-123", topicPrefix: "438M", name: "Dyson"), credential: "credential")
        store.remove(.dyson)
        XCTAssertTrue(dyson.commands.isEmpty); XCTAssertNil(secrets.values["dyson"]); XCTAssertNil(config.saved.dyson)
        store.stop()
    }
    func testOfflineCommandsAreNotQueued() {
        let (store, hue, dyson, _, _, _) = fixture()
        store.setDyson(["fpwr": "ON"])
        store.setLight(HueLight(id: "light", name: "Desk", isOn: false, brightness: 20, reachable: true), on: true)
        XCTAssertEqual(hue.commands, 0); XCTAssertTrue(dyson.commands.isEmpty)
    }
    func testBadgeAndCommandConfirmation() async throws {
        let (store, _, client, _, _, clock) = fixture()
        client.snapshot.temperature = SensorReading(value: 23.4, receivedAt: clock.now)
        try await store.connectDyson(DysonConfiguration(host: "dyson.local", serial: "ABC-123", topicPrefix: "438M", name: "Dyson"), credential: "credential")
        XCTAssertEqual(store.badge, "23°")
        store.setDyson(["fpwr": "ON", "auto": "OFF", "fnsp": "0007"])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(store.dysonPending); XCTAssertEqual(store.dyson.speed, 7); XCTAssertTrue(store.dyson.isOn)
        client.onConnection?(.offline, nil); XCTAssertNil(store.badge)
        store.stop()
    }
    func testUnconfirmedCommandTimesOut() async throws {
        let (store, _, client, _, _, _) = fixture(); client.confirm = false
        try await store.connectDyson(DysonConfiguration(host: "dyson.local", serial: "ABC-123", topicPrefix: "438M", name: "Dyson"), credential: "credential")
        store.setDyson(["fpwr": "ON"])
        for _ in 0..<500 { await Task.yield() }
        XCTAssertFalse(store.dysonPending); XCTAssertEqual(store.dysonError, ControlError.timeout.localizedDescription)
        store.stop()
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    static func install(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { lock.withLock { Self.handler = handler } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        let (status, data) = handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor final class MyDysonTests: XCTestCase {
    // Synthetic ciphertext for {"apPasswordHash":"test-credential"}.
    private let encrypted = "juMwpAl06WHHsg7JAUz6Xem4FN8/1ZpVzLxcTfMlWw1lk/mxbhAbrl7nFB/aBLEk"
    func client() -> MyDysonClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return MyDysonClient(sessionConfiguration: config)
    }
    func testKnownCredentialFixtureAndFirmwareTopicVariant() throws {
        XCTAssertEqual(try MyDysonClient.decryptCredential(encrypted), "test-credential")
        let data = Data("[{\"Serial\":\"ABC-123\",\"Name\":\"Bedroom\",\"ProductType\":\"438\",\"Version\":\"438MPF.00.01\",\"LocalCredentials\":\"\(encrypted)\"}]".utf8)
        let devices = try MyDysonClient.parseManifest(data)
        XCTAssertEqual(devices.first?.topicPrefix, "438M"); XCTAssertEqual(devices.first?.credential, "test-credential")
    }
    func testCompleteLoginAndReset() async throws {
        let encrypted = encrypted
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/v1/provisioningservice/application/Android/version": return (200, Data(#""5.0""#.utf8))
            case "/v3/userregistration/email/userstatus": return (200, Data(#"{"accountStatus":"ACTIVE"}"#.utf8))
            case "/v3/userregistration/email/auth": return (200, Data(#"{"challengeId":"challenge"}"#.utf8))
            case "/v3/userregistration/email/verify": return (200, Data(#"{"token":"test-token","tokenType":"Bearer"}"#.utf8))
            case "/v2/provisioningservice/manifest":
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" else { return (401, Data()) }
                return (200, Data("[{\"Serial\":\"ABC-123\",\"ProductType\":\"438M\",\"LocalCredentials\":\"\(encrypted)\"}]".utf8))
            default: return (404, Data())
            }
        }
        let client = client(); try await client.requestCode(email: "test@example.com", country: "CZ")
        let devices = try await client.verify(code: "123456", password: "test-password")
        XCTAssertEqual(devices.count, 1)
        do { _ = try await client.verify(code: "123456", password: "test-password"); XCTFail("Session must be cleared") } catch { }
    }
    func testRateLimitIsActionable() async {
        StubURLProtocol.install { request in
            if request.url!.path.contains("version") { return (200, Data()) }
            if request.url!.path.contains("userstatus") { return (200, Data(#"{"accountStatus":"ACTIVE"}"#.utf8)) }
            return (429, Data())
        }
        do { try await client().requestCode(email: "test@example.com", country: "CZ"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Too many requests")) }
    }
    func testInvalidCodeAndReset() async throws {
        StubURLProtocol.install { request in
            if request.url!.path.contains("version") { return (200, Data()) }
            if request.url!.path.contains("userstatus") { return (200, Data(#"{"accountStatus":"ACTIVE"}"#.utf8)) }
            if request.url!.path.hasSuffix("/auth") { return (200, Data(#"{"challengeId":"challenge"}"#.utf8)) }
            return (400, Data())
        }
        let client = client(); try await client.requestCode(email: "test@example.com", country: "CZ")
        do { _ = try await client.verify(code: "bad-code", password: "test-password"); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ControlError.authorization.localizedDescription) }
        client.reset()
        do { _ = try await client.verify(code: "123456", password: "test-password"); XCTFail() } catch { }
    }
    func testCommandDeadlineCancelsSlowOperation() async {
        do {
            try await withCommandDeadline(seconds: 0.02) { try await Task.sleep(for: .seconds(60)) }
            XCTFail()
        } catch { XCTAssertEqual(error.localizedDescription, ControlError.timeout.localizedDescription) }
    }
}


private final class TestChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
    func cancel(_ challenge: URLAuthenticationChallenge) { }
}
private final class TestProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    let fixtureTrust: SecTrust
    override var serverTrust: SecTrust? { fixtureTrust }
    init(trust: SecTrust) {
        fixtureTrust = trust
        super.init(host: "bridge.local", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("Not used by TLS tests") }
}

final class HueTrustTests: XCTestCase {
    // Synthetic certificates; no user's device identity or private keys are included.
    private let rootDER = "MIIDHTCCAgWgAwIBAgIUPipMSLBmaMK+zKT7UcPY4G4JJRkwDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTSG9tZUNvbnRyb2wgVGVzdCBDQTAeFw0yNjEwMDQxNzM3MjdaFw0zNjEwMDExNzM3MjdaMB4xHDAaBgNVBAMME0hvbWVDb250cm9sIFRlc3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC3CTmhA7x2hY/fcm8QXhsxFYPdNOpLFwJGoPcgZNVQviZzW8n5PeznYGlKsSoxlxZa43Os7lIikOkE6nmTAmD3afbBSbt6UQKZQ4mF0YynA7ACDzJdbt6g9Trjw5V1bUKR9USZNHn1M62HE7UJ9wUhtbMA8Sv2Fdykr/Bt45ld93nAFQIyeHQp/WFUBaOsLFRG2mY8KNZC71kt3zKzhLLCFwtQkp5wcX1K7FjfrYccdCUfPdqMRln+G5fJNik04zhg0Ap+gOiPw65yO/MnqeVTa0vySwoByYVuoOi3SwKK8lTxBhs/xLYrnrVGY0+d8j6J5pAIXiQaGhv8DHLaFXRNAgMBAAGjUzBRMB0GA1UdDgQWBBSnnMPDvnJLcq6901J+1zCEeA3ShDAfBgNVHSMEGDAWgBSnnMPDvnJLcq6901J+1zCEeA3ShDAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBTn3CE2I2kFMrAM2Ky05ugcFWv89TURPTWBc9mnXdLEUppVIkFGPPibmPnuwGMia592+IPl/R4rP8OqgPe5XVHjwVB3mE71cBnHKy6+q+yGVCfPTZ1BQOp+VZiQ6I6e4AkVkOyxGQYjX3fpiHwGrhh5VaBIETVoWenIo7mfD+l9apZBxiFYczcSKiQKB8CQlG7XDYk/KjlH4ut7zZUpUONJNArRVseLMhUk/qsWiCK9SbM3bRwSgCu7fjEkJ7uPSZJJSjGjgKKXOGDC+ZVeeKKclni8XUbRfvPw3BDhpHNOZXdXOkscwiweG+6prv8WFwTo/zZNms+JX0tdTBxeW2g"
    private let leafDER = "MIIDCTCCAfGgAwIBAgIUEFaimR0a+66l+GKRqqcL/hGZYWcwDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTSG9tZUNvbnRyb2wgVGVzdCBDQTAeFw0yNjEwMDQxNzM3MjdaFw0zNjEwMDExNzM3MjdaMBsxGTAXBgNVBAMMEDAwMTc4OGZmZmUxMjM0NTYwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/to/EliJ/BcbdCLC7X1Gar5FKczV5I4SRN18cHgAjs6sL3oLctHxF3whKGowZWS4KG06F0bBik2jrmmNn7g5h69m4e792tonyU0KmxWjeF2079i5i5emCEXgm8YkxIypWlQyIB6LwAYJhrLFACSLj8Iy8Y1Thx6T3Vwf7CZ4hkqZbZIlPy1Evhrpwbn1Mhhraz8Wx9N05NlvKLXOAm2Q4/uMzCpyiWkH0FhBrAcPO3Bapu51udMgUUbZidRP/XnzC1Sl83BMsBdpwqZaeuThnHT2oTPIKWsadCnBpe4qGIVNSnKjFu7BAgAJi0hgsyXFHKuOvFQSMGOTJaHxNxtTRAgMBAAGjQjBAMB0GA1UdDgQWBBRYZYRQkSTwNleRHUv8iekaQMa8+jAfBgNVHSMEGDAWgBSnnMPDvnJLcq6901J+1zCEeA3ShDANBgkqhkiG9w0BAQsFAAOCAQEAOHon8YoGh3Dvo6j56aD+j0v7puFbK+JknHEQD5v/5J3DTsHO64TiPGj8s9kAKZwtGHtvc1x1gvcu1BJ8BPtVJNVs1AStJs2VEsaLAk7+swn1bp7dun79I6dRfcfINXKVSRGqF+G1yW1rNwL93QtJbUWOgpPOG9AzyVIoEOM8dU0kyOEdPik66nPWmlUi1wA70bF53gTS/UzGV1uAaifZI8HW8MTjyW6iJFX9cNSHKeX0xjSBeZThpd7uxG2O/9qORebayqzVS/YvbXgu6qQCsq3hmErJkUBSDw4GL0qDRJkFO7EY9x16vjmJGx8C+B7ayKSTJKutVa8G8fqcePmJhw=="
    private func certificate(_ encoded: String) -> SecCertificate {
        SecCertificateCreateWithData(nil, Data(base64Encoded: encoded)! as CFData)!
    }
    private func challenge() throws -> URLAuthenticationChallenge {
        var trust: SecTrust?
        let result = SecTrustCreateWithCertificates([certificate(leafDER)] as CFArray, SecPolicyCreateSSL(true, "bridge.local" as CFString), &trust)
        XCTAssertEqual(result, errSecSuccess)
        return URLAuthenticationChallenge(protectionSpace: TestProtectionSpace(trust: trust!), proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: TestChallengeSender())
    }
    func testSessionAndStreamingTaskUseSameBridgeTrust() throws {
        let delegate = HueTrustDelegate(bridgeID: "001788fffe123456", rootCertificates: [certificate(rootDER)])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://bridge.local/api/config")!)
        let sessionHandled = expectation(description: "Session trust validated")
        delegate.urlSession(session, didReceive: try challenge()) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential); XCTAssertNotNil(credential); sessionHandled.fulfill()
        }
        let taskHandled = expectation(description: "Streaming task trust validated")
        delegate.urlSession(session, task: task, didReceive: try challenge()) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential); XCTAssertNotNil(credential); taskHandled.fulfill()
        }
        wait(for: [sessionHandled, taskHandled], timeout: 1)
        XCTAssertEqual(delegate.certificateID, "001788fffe123456")
    }
    func testStreamingRejectsWrongBridgeIdentity() throws {
        let delegate = HueTrustDelegate(bridgeID: "001788fffe654321", rootCertificates: [certificate(rootDER)])
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://bridge.local")!)
        let handled = expectation(description: "Wrong bridge rejected")
        delegate.urlSession(session, task: task, didReceive: try challenge()) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge); XCTAssertNil(credential); handled.fulfill()
        }
        wait(for: [handled], timeout: 1)
        XCTAssertNil(delegate.certificateID)
    }
    func testStreamingRejectsUntrustedCertificate() throws {
        let delegate = HueTrustDelegate(bridgeID: "001788fffe123456", rootCertificates: [])
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://bridge.local")!)
        let handled = expectation(description: "Untrusted CA rejected")
        delegate.urlSession(session, task: task, didReceive: try challenge()) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge); XCTAssertNil(credential); handled.fulfill()
        }
        wait(for: [handled], timeout: 1)
        XCTAssertNil(delegate.certificateID)
    }
}
