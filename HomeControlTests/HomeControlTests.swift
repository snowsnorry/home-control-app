import XCTest
import AppKit
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
    var confirmLights = false
    var lightCommandIDs: [String] = []
    var delayRecall = false
    var rejectRecall = false
    private var recallContinuation: CheckedContinuation<Void, Never>?
    func finishRecall() { recallContinuation?.resume(); recallContinuation = nil }
    func identify(host: String, bridgeID: String?) async throws -> HueConfiguration { HueConfiguration(host: host, bridgeID: bridgeID ?? "001788fffe123456") }
    func pair(configuration: HueConfiguration) async throws -> String { if rejectPair { throw ControlError.authorization }; return "hue-key" }
    var scenes: [HueScene] = []
    func fetchSnapshot(configuration: HueConfiguration, key: String) async throws -> HueBridgeSnapshot { HueBridgeSnapshot(lights: lights, scenes: scenes) }
    func recallScene(configuration: HueConfiguration, key: String, id: String) async throws {
        commands += 1
        if rejectRecall { throw ControlError.message("Scene recall failed") }
        if delayRecall { await withCheckedContinuation { recallContinuation = $0 } }
        if let index = scenes.firstIndex(where: { $0.id == id }) { scenes[index].active = "static" }
    }
    func setLight(configuration: HueConfiguration, key: String, id: String, on: Bool?, brightness: Double?) async throws {
        commands += 1
        lightCommandIDs.append(id)
        if confirmLights, let index = lights.firstIndex(where: { $0.id == id }) {
            if let on { lights[index].isOn = on }; if let brightness { lights[index].brightness = brightness }
        }
    }
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

final class AirQualityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)
    func testDominantPollutantUsesQualityScaleInsteadOfRawValues() {
        var snapshot = DysonSnapshot()
        snapshot.pm25 = SensorReading(value: 14, receivedAt: now)
        snapshot.pm10 = SensorReading(value: 20, receivedAt: now)
        snapshot.voc = SensorReading(value: 5.2, receivedAt: now)
        snapshot.nitrogenDioxide = SensorReading(value: 0.4, receivedAt: now)
        let dominant = snapshot.dominantPollutant(at: now)
        XCTAssertEqual(dominant?.pollutant, .voc)
        XCTAssertEqual(dominant?.reading.value, 5.2)
        XCTAssertEqual(dominant?.quality, .fair)
        XCTAssertEqual(dominant?.pollutant.unit, "")
        XCTAssertEqual(dominant?.pollutant.fraction, 1)
    }
    func testEachPollutantCanDominate() {
        for pollutant in DysonPollutant.allCases {
            var snapshot = DysonSnapshot()
            snapshot.pm25 = SensorReading(value: 0, receivedAt: now)
            snapshot.pm10 = SensorReading(value: 0, receivedAt: now)
            snapshot.voc = SensorReading(value: 0, receivedAt: now)
            snapshot.nitrogenDioxide = SensorReading(value: 0, receivedAt: now)
            let reading = SensorReading(value: pollutant.boundaries[2], receivedAt: now)
            switch pollutant {
            case .pm25: snapshot.pm25 = reading
            case .pm10: snapshot.pm10 = reading
            case .voc: snapshot.voc = reading
            case .nitrogenDioxide: snapshot.nitrogenDioxide = reading
            }
            XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, pollutant)
            XCTAssertEqual(snapshot.airQuality(at: now, connected: true), .veryPoor)
        }
    }
    func testDominantPollutantComparesWithinBandsAndKeepsExactTiesStable() {
        var snapshot = DysonSnapshot()
        snapshot.pm25 = SensorReading(value: 42, receivedAt: now)
        snapshot.voc = SensorReading(value: 6, receivedAt: now)
        XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, .voc)
        snapshot.pm25?.value = 36
        snapshot.voc?.value = 4
        XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, .pm25)
        snapshot.pm25?.value = 18
        snapshot.voc?.value = 3
        XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, .voc)
        snapshot.pm25?.value = 80
        snapshot.voc?.value = 12
        XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, .voc)
    }
    func testDominantPollutantIgnoresStaleAndInvalidReadings() {
        var snapshot = DysonSnapshot()
        snapshot.pm25 = SensorReading(value: 14, receivedAt: now)
        snapshot.voc = SensorReading(value: 9, receivedAt: now.addingTimeInterval(-120))
        snapshot.pm10 = SensorReading(value: .infinity, receivedAt: now)
        snapshot.nitrogenDioxide = SensorReading(value: -1, receivedAt: now)
        XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, .pm25)
        let later = now.addingTimeInterval(120)
        XCTAssertNil(snapshot.dominantPollutant(at: later))
        XCTAssertEqual(snapshot.dominantPollutant(at: later, requireFresh: false)?.pollutant, .voc)
        snapshot.pm25 = nil; snapshot.voc = nil
        XCTAssertNil(snapshot.dominantPollutant(at: later, requireFresh: false))
    }
    func testEveryBoundary() {
        for (keyPath, boundaries) in [(\DysonSnapshot.pm25, [36.0, 54, 71]), (\DysonSnapshot.pm10, [51.0, 76, 101]),
                                       (\DysonSnapshot.voc, [4.0, 7, 9]), (\DysonSnapshot.nitrogenDioxide, [4.0, 7, 9])] {
            var snapshot = DysonSnapshot()
            snapshot[keyPath: keyPath] = SensorReading(value: 0, receivedAt: now)
            XCTAssertEqual(snapshot.airQuality(at: now, connected: true), .good)
            for (index, boundary) in boundaries.enumerated() {
                snapshot[keyPath: keyPath] = SensorReading(value: boundary - 0.01, receivedAt: now)
                XCTAssertEqual(snapshot.airQuality(at: now, connected: true)?.rawValue, index)
                snapshot[keyPath: keyPath] = SensorReading(value: boundary, receivedAt: now)
                XCTAssertEqual(snapshot.airQuality(at: now, connected: true)?.rawValue, index + 1)
            }
        }
    }
    func testWorstFreshReadingAndOfflineNeutral() {
        var snapshot = DysonSnapshot()
        snapshot.pm25 = SensorReading(value: 2, receivedAt: now)
        snapshot.voc = SensorReading(value: 8, receivedAt: now)
        snapshot.pm10 = SensorReading(value: 500, receivedAt: now.addingTimeInterval(-120))
        XCTAssertEqual(snapshot.airQuality(at: now, connected: true), .poor)
        XCTAssertNil(snapshot.airQuality(at: now, connected: false))
        XCTAssertNil(snapshot.airQuality(at: now.addingTimeInterval(120), connected: true))
    }
    func testMissingAndInvalidMeasurementsAreNotGoodAir() {
        var snapshot = DysonSnapshot()
        XCTAssertNil(snapshot.airQuality(at: now, connected: true))
        for value in [-1.0, Double.nan, Double.infinity] {
            snapshot.pm25 = SensorReading(value: value, receivedAt: now)
            XCTAssertNil(snapshot.airQuality(at: now, connected: true))
        }
    }
    func testHighResolutionZeroAndGasIndices() throws {
        let data = Data(#"{"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"p25r":"0000","pm25":"0050","p10r":"0010","pm10":"9999","va10":"0075","noxl":"0090"}}"#.utf8)
        let snapshot = try DysonCodec.updated(DysonSnapshot(), payload: data, now: now)
        XCTAssertEqual(snapshot.pm25?.value, 0)
        XCTAssertEqual(snapshot.pm10?.value, 10)
        XCTAssertEqual(snapshot.voc?.value, 7.5)
        XCTAssertEqual(snapshot.nitrogenDioxide?.value, 9)
        XCTAssertEqual(snapshot.airQuality(at: now, connected: true), .veryPoor)
    }
    func testFallbacksSentinelsAndPartialUpdates() throws {
        var snapshot = try DysonCodec.updated(DysonSnapshot(), payload: Data(#"{"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"p25r":"FAIL","pm25":"0042","pm10":"0012","va10":"0010"}}"#.utf8), now: now)
        XCTAssertEqual(snapshot.pm25?.value, 42); XCTAssertEqual(snapshot.pm10?.value, 12)
        snapshot = try DysonCodec.updated(snapshot, payload: Data(#"{"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"va10":"OFF","noxl":"-10"}}"#.utf8), now: now.addingTimeInterval(10))
        XCTAssertEqual(snapshot.pm25?.value, 42); XCTAssertEqual(snapshot.pm25?.receivedAt, now)
        XCTAssertNil(snapshot.voc?.value); XCTAssertNil(snapshot.nitrogenDioxide?.value)
    }
    func testPollutantSentinelsAndNonfiniteValues() throws {
        for value in ["OFF", "INIT", "FAIL", "NONE", "NaN", "inf", "-1", "10000"] {
            let data = Data("{\"msg\":\"ENVIRONMENTAL-CURRENT-SENSOR-DATA\",\"data\":{\"p25r\":\"\(value)\",\"p10r\":\"\(value)\",\"va10\":\"\(value)\",\"noxl\":\"\(value)\"}}".utf8)
            let snapshot = try DysonCodec.updated(DysonSnapshot(), payload: data, now: now)
            XCTAssertNil(snapshot.pm25?.value); XCTAssertNil(snapshot.pm10?.value)
            XCTAssertNil(snapshot.voc?.value); XCTAssertNil(snapshot.nitrogenDioxide?.value)
            XCTAssertNil(snapshot.airQuality(at: now, connected: true))
        }
    }
}

@MainActor final class SceneTests: XCTestCase {
    let sceneID = "BA109016-1CD5-45D0-8395-1797FCAD3AAB"
    func testSnapshotIncludesGroupsActivityAndDeviceArchetypes() throws {
        let data = Data(#"{"errors":[],"data":[{"id":"room","type":"room","metadata":{"name":"Office"}},{"id":"device","type":"device","metadata":{"name":"Desk","archetype":"table_shade"}},{"id":"plugdevice","type":"device","metadata":{"archetype":"unknown_archetype"},"product_data":{"product_archetype":"plug"}},{"id":"lamp","type":"light","owner":{"rid":"device"},"dimming":{"brightness":42}},{"id":"plug","type":"light","owner":{"rid":"plugdevice"}},{"id":"scene","type":"scene","metadata":{"name":"Focus"},"group":{"rid":"room"},"status":{"active":"static"}},{"id":"ignored","type":"smart_scene","metadata":{"name":"Schedule"}}]}"#.utf8)
        let snapshot = try HueClient.parseSnapshot(data)
        XCTAssertEqual(snapshot.lights.first(where: { $0.id == "lamp" })?.archetype, "table_shade")
        XCTAssertEqual(snapshot.lights.first(where: { $0.id == "plug" })?.archetype, "plug")
        XCTAssertFalse(snapshot.lights.first(where: { $0.id == "plug" })!.supportsBrightness)
        XCTAssertEqual(snapshot.scenes.count, 1)
        XCTAssertEqual(snapshot.scenes[0].groupName, "Office"); XCTAssertTrue(snapshot.scenes[0].isActive)
    }
    func testRecallBodyAndInvalidID() throws {
        let body = try HueClient.sceneRecallBody(id: sceneID)
        XCTAssertEqual((body["recall"] as? [String: String])?["action"], "active")
        XCTAssertThrowsError(try HueClient.sceneRecallBody(id: "scene/path"))
    }
    func testRecallRequestAndHueFailure() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let client = HueClient(sessionConfiguration: config)
        let expectedPath = "/clip/v2/resource/scene/" + sceneID
        StubURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, expectedPath)
            XCTAssertEqual(request.value(forHTTPHeaderField: "hue-application-key"), "test-key")
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
            XCTAssertEqual((body["recall"] as? [String: String])?["action"], "active")
            return (200, Data(#"{"errors":[],"data":[]}"#.utf8))
        }
        try await client.recallScene(configuration: HueConfiguration(host: "hue.local", bridgeID: "001788fffe123456"), key: "test-key", id: sceneID)
        StubURLProtocol.install { _ in (200, Data(#"{"errors":[{"description":"failed"}],"data":[]}"#.utf8)) }
        do {
            try await client.recallScene(configuration: HueConfiguration(host: "hue.local", bridgeID: "001788fffe123456"), key: "test-key", id: sceneID)
            XCTFail("Hue errors must fail recall")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Hue")) }
    }
    func testOldConfigurationAndSelectionPersistence() throws {
        let old = try JSONDecoder().decode(SavedConfiguration.self, from: Data(#"{"hue":{"host":"hue.local","bridgeID":"bridge"}}"#.utf8))
        XCTAssertNil(old.hue?.selectedSceneIDs)
        let persistence = MemoryConfiguration(); persistence.saved = old
        let store = HomeStore(hue: FakeHue(), dyson: FakeDyson(), secrets: MemorySecrets(), persistence: persistence, clock: FakeClock())
        XCTAssertTrue(store.visibleScenes.isEmpty)
        store.setSceneVisible(sceneID, visible: true)
        XCTAssertEqual(persistence.saved.hue?.selectedSceneIDs, [sceneID])
        let restored = try JSONDecoder().decode(SavedConfiguration.self, from: JSONEncoder().encode(persistence.saved))
        XCTAssertEqual(restored.hue?.selectedSceneIDs, [sceneID])
        persistence.fail = true
        store.setSceneVisible(sceneID, visible: false)
        XCTAssertEqual(store.configuration.hue?.selectedSceneIDs, [sceneID]); XCTAssertNotNil(store.storageError)
    }
    func testSameBridgePreservesSelectionAndNewBridgeResetsIt() async throws {
        let persistence = MemoryConfiguration(); persistence.saved.hue = HueConfiguration(host: "hue.local", bridgeID: "first", selectedSceneIDs: [sceneID])
        let store = HomeStore(hue: FakeHue(), dyson: FakeDyson(), secrets: MemorySecrets(), persistence: persistence, clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "new-address.local", bridgeID: "first"))
        XCTAssertEqual(store.configuration.hue?.selectedSceneIDs, [sceneID])
        try await store.connectHue(HueConfiguration(host: "other.local", bridgeID: "second"))
        XCTAssertTrue((store.configuration.hue?.selectedSceneIDs ?? []).isEmpty)
        store.stop()
    }
    func testBrightnessTurnsOnAndPlugRejectsBrightness() async throws {
        let hue = FakeHue(); hue.confirmLights = true
        hue.lights = [HueLight(id: "lamp", name: "Lamp", isOn: false, brightness: 20, reachable: true), HueLight(id: "plug", name: "Plug", isOn: false, brightness: nil, reachable: true)]
        let store = HomeStore(hue: hue, dyson: FakeDyson(), secrets: MemorySecrets(), persistence: MemoryConfiguration(), clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "bridge"))
        for _ in 0..<20 { await Task.yield() }
        store.setLight(store.lights[1], brightness: 50)
        XCTAssertEqual(hue.commands, 0)
        store.setLight(store.lights[0], brightness: 50)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(hue.commands, 1); XCTAssertTrue(store.lights[0].isOn)
        XCTAssertEqual(store.lights[0].brightness, 50); XCTAssertTrue(store.pendingLights.isEmpty)
        store.stop()
    }
    func testScenePendingBlocksLightCommandsAndRefreshesActivity() async throws {
        let hue = FakeHue(); hue.delayRecall = true
        let scene = HueScene(id: sceneID, name: "Focus", groupID: "room", groupName: "Office", active: "inactive")
        hue.scenes = [scene]; hue.lights = [HueLight(id: "lamp", name: "Lamp", isOn: false, brightness: 20, reachable: true)]
        let store = HomeStore(hue: hue, dyson: FakeDyson(), secrets: MemorySecrets(), persistence: MemoryConfiguration(), clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "bridge"))
        for _ in 0..<20 { await Task.yield() }
        store.recallScene(scene); XCTAssertNil(store.pendingSceneID)
        store.setSceneVisible(sceneID, visible: true)
        store.recallScene(scene); XCTAssertEqual(store.pendingSceneID, sceneID)
        store.setLight(store.lights[0], on: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(hue.commands, 1)
        hue.finishRecall()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertNil(store.pendingSceneID); XCTAssertTrue(store.visibleScenes[0].isActive)
        hue.scenes = []
        store.reconnect(.hue)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.visibleScenes.isEmpty)
        XCTAssertEqual(store.configuration.hue?.selectedSceneIDs, [sceneID])
        store.stop()
    }
    func testOldRecallCannotOverwriteReconnectedBridge() async throws {
        let hue = FakeHue(); hue.delayRecall = true
        let scene = HueScene(id: sceneID, name: "Focus", groupID: "room", groupName: "Office", active: nil)
        hue.scenes = [scene]
        let store = HomeStore(hue: hue, dyson: FakeDyson(), secrets: MemorySecrets(), persistence: MemoryConfiguration(), clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "bridge"))
        for _ in 0..<20 { await Task.yield() }
        store.setSceneVisible(sceneID, visible: true); store.recallScene(scene)
        for _ in 0..<20 { await Task.yield() }
        store.reconnect(.hue)
        hue.scenes = []; hue.finishRecall()
        for _ in 0..<60 { await Task.yield() }
        XCTAssertNil(store.pendingSceneID); XCTAssertTrue(store.scenes.isEmpty); XCTAssertNil(store.hueError)
        store.stop()
    }
    func testSceneErrorClearsPendingWithoutChangingActivity() async throws {
        let hue = FakeHue(); hue.rejectRecall = true
        let scene = HueScene(id: sceneID, name: "Focus", groupID: "room", groupName: "Office", active: "inactive")
        hue.scenes = [scene]
        let store = HomeStore(hue: hue, dyson: FakeDyson(), secrets: MemorySecrets(), persistence: MemoryConfiguration(), clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "bridge"))
        for _ in 0..<20 { await Task.yield() }
        store.setSceneVisible(sceneID, visible: true); store.recallScene(scene)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertNil(store.pendingSceneID); XCTAssertEqual(store.hueError, "Scene recall failed")
        XCTAssertFalse(store.visibleScenes[0].isActive)
        store.stop()
    }
    func testEscapeSelectionAndIcons() {
        let presentation = PanelPresentation()
        XCTAssertFalse(presentation.closeBrightness())
        presentation.selectedLight = .init(id: "lamp")
        XCTAssertTrue(presentation.closeBrightness()); XCTAssertNil(presentation.selectedLight)
        for archetype in ["table_shade", "floor_shade", "ceiling_round", "hue_lightstrip", "plug", "spot_bulb", "unknown"] {
            for on in [true, false] {
                XCTAssertNotNil(NSImage(systemSymbolName: HueIcon.symbol(archetype: archetype, on: on), accessibilityDescription: nil), archetype)
            }
        }
    }
}

@MainActor final class ScenePaletteTests: XCTestCase {
    private func scene(_ values: [String: Any]) throws -> HueScene {
        var resource = values
        resource.merge(["id": "scene", "type": "scene", "metadata": ["name": "Palette"], "group": ["rid": "room"]]) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["errors": [], "data": [resource]])
        return try XCTUnwrap(HueClient.parseSnapshot(data).scenes.first)
    }
    private func xy(_ x: Double, _ y: Double) -> [String: Any] { ["color": ["xy": ["x": x, "y": y]]] }

    func testPalettePreservesBridgeOrderAndOverridesActions() throws {
        let value = try scene(["palette": ["color": [xy(0.19, 0.24), xy(0.64, 0.33)]],
                               "actions": [["action": xy(0.45, 0.24)]]])
        XCTAssertEqual(value.colors, [.xy(x: 0.19, y: 0.24)!, .xy(x: 0.64, y: 0.33)!])
        XCTAssertEqual(value.primaryColor, value.colors.first)
    }
    func testWhitePaletteAndMixedPalette() throws {
        let value = try scene(["palette": ["color": [xy(0.19, 0.24)],
                                           "color_temperature": [["color_temperature": ["mirek": 450]]]]])
        XCTAssertEqual(value.colors.count, 2)
        XCTAssertEqual(value.colors.last, .temperature(mirek: 450))
        let white = try scene(["palette": ["color_temperature": [["color_temperature": ["mirek": 153]]]]])
        XCTAssertEqual(white.primaryColor, .temperature(mirek: 153))
    }
    func testStaticActionsIgnoreOffAndZeroBrightnessAndDeduplicate() throws {
        var off = xy(0.45, 0.24); off["on"] = ["on": false]
        var zero = xy(0.64, 0.33); zero["dimming"] = ["brightness": 0]
        var dim = xy(0.19, 0.24); dim["dimming"] = ["brightness": 1]
        let value = try scene(["actions": [off, zero, dim, dim, ["color_temperature": ["mirek": 400]], [:]].map { ["action": $0] }])
        XCTAssertEqual(value.colors, [.xy(x: 0.19, y: 0.24)!, .temperature(mirek: 400)!])
    }
    func testMalformedPaletteSkipsBadEntriesAndFallsBackToActions() throws {
        let value = try scene(["palette": ["color": [xy(0.3, 0), xy(0.8, 0.8), xy(0.19, 0.24), ["color": ["xy": ["x": "wrong", "y": 0.4]]]],
                                           "color_temperature": [["color_temperature": ["mirek": 0]]]]])
        XCTAssertEqual(value.colors, [.xy(x: 0.19, y: 0.24)!])
        let fallback = try scene(["palette": ["color": [xy(-1, 0.4)]], "actions": [["action": xy(0.45, 0.24)]]])
        XCTAssertEqual(fallback.colors, [.xy(x: 0.45, y: 0.24)!])
        let neutral = try scene([:])
        XCTAssertTrue(neutral.colors.isEmpty); XCTAssertNil(neutral.primaryColor)
    }
    func testXYConversionProducesRecognizableNormalizedDisplayColors() throws {
        let red = try XCTUnwrap(HueSceneColor.xy(x: 0.675, y: 0.322))
        XCTAssertEqual(red.red, 1, accuracy: 0.001); XCTAssertLessThan(red.green, 0.3); XCTAssertLessThan(red.blue, 0.1)
        let blue = try XCTUnwrap(HueSceneColor.xy(x: 0.1355, y: 0.0399))
        XCTAssertEqual(blue.blue, 1, accuracy: 0.001); XCTAssertLessThan(blue.red, 0.1)
        let white = try XCTUnwrap(HueSceneColor.xy(x: 0.3127, y: 0.3290))
        XCTAssertGreaterThan(min(white.red, white.green, white.blue), 0.9)
        for color in [red, blue, white] {
            for channel in [color.red, color.green, color.blue] { XCTAssertTrue(channel.isFinite && (0...1).contains(channel)) }
        }
    }
    func testTemperatureConversionAndInvalidCoordinates() throws {
        let warm = try XCTUnwrap(HueSceneColor.temperature(mirek: 500))
        let cool = try XCTUnwrap(HueSceneColor.temperature(mirek: 153))
        XCTAssertGreaterThan(warm.red, warm.blue + 0.5); XCTAssertGreaterThan(cool.blue, warm.blue)
        XCTAssertGreaterThan(cool.green, 0.9)
        for (x, y) in [(Double.nan, 0.3), (0.3, Double.infinity), (-0.1, 0.3), (0.3, 0), (0.8, 0.8)] {
            XCTAssertNil(HueSceneColor.xy(x: x, y: y))
        }
        for mirek in [0, 152, 501, Double.nan, Double.infinity] { XCTAssertNil(HueSceneColor.temperature(mirek: mirek)) }
    }
}

@MainActor final class PanelHeightTests: XCTestCase {
    func testTallScreenStartsAtExistingHeightAndExpandsToAllContent() {
        let limits = PanelHeightLimits(contentHeight: 920, availableHeight: 1400)
        XCTAssertEqual(limits.height(preferred: nil), 700)
        XCTAssertEqual(limits.maximum, 932)
        XCTAssertTrue(limits.canResize)
        XCTAssertEqual(limits.height(preferred: 2000), 932)
        XCTAssertEqual(limits.height(preferred: 300), 700)
    }
    func testShortContentDoesNotCreateBlankSpaceOrAResizeHandle() {
        let limits = PanelHeightLimits(contentHeight: 480, availableHeight: 1400)
        XCTAssertEqual(limits.minimum, 480); XCTAssertEqual(limits.maximum, 480)
        XCTAssertFalse(limits.canResize)
        XCTAssertEqual(limits.height(preferred: 900), 480)
    }
    func testScreenBoundsCapHeightEvenWhenContentIsLonger() {
        let limits = PanelHeightLimits(contentHeight: 1600, availableHeight: 1080)
        XCTAssertEqual(limits.maximum, 1080)
        XCTAssertEqual(limits.height(preferred: 2000), 1080)
        let smallScreen = PanelHeightLimits(contentHeight: 920, availableHeight: 620)
        XCTAssertEqual(smallScreen.minimum, 620); XCTAssertEqual(smallScreen.maximum, 620)
        XCTAssertFalse(smallScreen.canResize)
    }
    func testPreferredHeightSurvivesPopoverDismissalAndAdaptsToContentAndScreen() {
        let presentation = PanelPresentation()
        presentation.preferredPanelHeight = 850
        presentation.selectedLight = .init(id: "lamp")
        XCTAssertTrue(presentation.closeBrightness())
        let reopened = PanelHeightLimits(contentHeight: 920, availableHeight: 1400)
        XCTAssertEqual(reopened.height(preferred: presentation.preferredPanelHeight), 850)
        let fewerDevices = PanelHeightLimits(contentHeight: 780, availableHeight: 1400)
        XCTAssertEqual(fewerDevices.height(preferred: presentation.preferredPanelHeight), 792)
        let smallerScreen = PanelHeightLimits(contentHeight: 920, availableHeight: 740)
        XCTAssertEqual(smallerScreen.height(preferred: presentation.preferredPanelHeight), 740)
    }
}

@MainActor final class SceneMatchingTests: XCTestCase {
    private func scene() -> HueScene {
        HueScene(id: "scene", name: "Evening", groupID: "room", groupName: "Living", active: "inactive", actions: [
            HueSceneAction(lightID: "lamp", on: true, brightness: 75, colorXY: HueXY(x: 0.4, y: 0.3)),
            HueSceneAction(lightID: "lamp-plug", on: true),
            HueSceneAction(lightID: "off-lamp", on: false, brightness: 50)
        ])
    }
    private func lights() -> [HueLight] {
        [HueLight(id: "lamp", name: "Lamp", isOn: true, brightness: 75, reachable: true, colorXY: HueXY(x: 0.4, y: 0.3)),
         HueLight(id: "lamp-plug", name: "Lamp plug", isOn: true, brightness: nil, reachable: true, archetype: "plug"),
         HueLight(id: "off-lamp", name: "Off lamp", isOn: false, brightness: 10, reachable: true),
         HueLight(id: "other-plug", name: "Other device", isOn: true, brightness: nil, reachable: true, archetype: "plug")]
    }
    func testMatchesAllSceneDevicesAndIgnoresOutsidePlug() {
        var lights = lights()
        XCTAssertTrue(scene().matches(lights))
        lights[3].isOn = false
        XCTAssertTrue(scene().matches(lights))
        lights[1].isOn = false
        XCTAssertFalse(scene().matches(lights))
    }
    func testOutsideLampBlocksActivityButOutsideApplianceDoesNot() {
        var lights = lights()
        XCTAssertTrue(scene().matches(lights))
        lights.append(HueLight(id: "outside-lamp", name: "Another lamp", isOn: true, brightness: 50, reachable: true))
        XCTAssertFalse(scene().matches(lights))
        lights[4].isOn = false
        XCTAssertTrue(scene().matches(lights))
        lights[3].archetype = "wall_shade" // A Hue plug configured as a lamp.
        XCTAssertFalse(scene().matches(lights))
        lights[3].isOn = false
        XCTAssertTrue(scene().matches(lights))
    }
    func testSmallBrightnessAndColorDifferencesMatchButSignificantChangesDoNot() {
        var lights = lights()
        lights[0].brightness = 72.1
        lights[0].colorXY = HueXY(x: 0.406, y: 0.307)
        XCTAssertTrue(scene().matches(lights))
        lights[0].brightness = 71.9
        XCTAssertFalse(scene().matches(lights))
        lights[0].brightness = 75
        lights[0].colorXY = HueXY(x: 0.408, y: 0.308)
        XCTAssertFalse(scene().matches(lights))
    }
    func testCurrentEveningBrightnessMismatchIsNotCausedByOutsidePlug() {
        var scene = self.scene()
        scene.actions = [
            HueSceneAction(lightID: "lamp", on: true, brightness: 75.1, colorXY: HueXY(x: 0.5608999, y: 0.4042)),
            HueSceneAction(lightID: "lamp2", on: true, brightness: 75.1, colorXY: HueXY(x: 0.5608999, y: 0.4042)),
            HueSceneAction(lightID: "lamp3", on: true, brightness: 75.1, colorXY: HueXY(x: 0.5608999, y: 0.4042)),
            HueSceneAction(lightID: "lamp-plug", on: true)
        ]
        var lights = [
            HueLight(id: "lamp", name: "Lamp 1", isOn: true, brightness: 75.1, reachable: true, colorXY: HueXY(x: 0.5608, y: 0.4039)),
            HueLight(id: "lamp2", name: "Lamp 2", isOn: true, brightness: 37.94, reachable: true, colorXY: HueXY(x: 0.5608, y: 0.4039)),
            HueLight(id: "lamp3", name: "Lamp 3", isOn: true, brightness: 60.08, reachable: true, colorXY: HueXY(x: 0.5608, y: 0.4039)),
            HueLight(id: "lamp-plug", name: "Lamp plug", isOn: true, brightness: nil, reachable: true, archetype: "wall_shade"),
            HueLight(id: "other-plug", name: "Appliance", isOn: true, brightness: nil, reachable: true, archetype: "plug")
        ]
        XCTAssertFalse(scene.matches(lights))
        lights[1].brightness = 73; lights[2].brightness = 77
        XCTAssertTrue(scene.matches(lights))
        lights[4].isOn = false
        XCTAssertTrue(scene.matches(lights))
        lights[3].isOn = false
        XCTAssertFalse(scene.matches(lights))
    }
    func testConfiguredLightIconOverridesPlugProductType() throws {
        let data = Data(#"{"errors":[],"data":[{"id":"device","type":"device","metadata":{"archetype":"plug"},"product_data":{"product_archetype":"plug"}},{"id":"lamp-plug","type":"light","owner":{"rid":"device"},"metadata":{"archetype":"wall_shade"},"on":{"on":true}},{"id":"appliance","type":"light","owner":{"rid":"device"},"metadata":{"archetype":"plug"},"on":{"on":true}}]}"#.utf8)
        let lights = try HueClient.parseResources(data)
        XCTAssertTrue(try XCTUnwrap(lights.first { $0.id == "lamp-plug" }).isLightingDevice)
        XCTAssertFalse(try XCTUnwrap(lights.first { $0.id == "appliance" }).isLightingDevice)
    }
    func testBrightnessColorPowerAndReachabilityMustMatch() {
        var lights = lights()
        lights[0].brightness = 75.5
        lights[0].colorXY = HueXY(x: 0.401, y: 0.299)
        XCTAssertTrue(scene().matches(lights))
        lights[0].brightness = 60
        XCTAssertFalse(scene().matches(lights))
        lights = self.lights(); lights[0].colorXY = HueXY(x: 0.5, y: 0.3)
        XCTAssertFalse(scene().matches(lights))
        lights = self.lights(); lights[2].isOn = true
        XCTAssertFalse(scene().matches(lights))
        lights = self.lights(); lights[1].reachable = false
        XCTAssertFalse(scene().matches(lights))
        XCTAssertFalse(scene().matches(Array(self.lights().prefix(1))))
    }
    func testTemperatureModeAndAllOffScenes() {
        var scene = HueScene(id: "s", name: "Warm", groupID: "r", groupName: "Room", actions: [HueSceneAction(lightID: "l", on: true, mirek: 400)])
        var light = HueLight(id: "l", name: "Light", isOn: true, brightness: 50, reachable: true, mirek: 401)
        XCTAssertTrue(scene.matches([light]))
        light.mirek = nil
        XCTAssertFalse(scene.matches([light]))
        scene.actions[0].on = false; light.isOn = false
        XCTAssertFalse(scene.matches([light]))
    }
    func testParserPreservesSceneTargetsAndCurrentColors() throws {
        let data = Data(#"{"errors":[],"data":[{"id":"lamp","type":"light","on":{"on":true},"dimming":{"brightness":75},"color":{"xy":{"x":0.4,"y":0.3}},"color_temperature":{"mirek":null}},{"id":"s","type":"scene","metadata":{"name":"Evening"},"group":{"rid":"r"},"actions":[{"target":{"rid":"lamp","rtype":"light"},"action":{"on":{"on":true},"dimming":{"brightness":75},"color":{"xy":{"x":0.4,"y":0.3}}}},{"target":{"rid":"plug","rtype":"light"},"action":{"on":{"on":true}}}]}]}"#.utf8)
        let snapshot = try HueClient.parseSnapshot(data)
        XCTAssertEqual(snapshot.scenes[0].enabledLightIDs, ["lamp", "plug"])
        XCTAssertEqual(snapshot.scenes[0].actions[0].colorXY, snapshot.lights[0].colorXY)
        XCTAssertEqual(snapshot.scenes[0].actions[0].brightness, 75)
    }
    func testActiveClickTurnsOffOnlyEnabledSceneMembers() async throws {
        let hue = FakeHue(); hue.confirmLights = true
        hue.lights = lights(); hue.scenes = [scene()]
        let store = HomeStore(hue: hue, dyson: FakeDyson(), secrets: MemorySecrets(), persistence: MemoryConfiguration(), clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "bridge"))
        for _ in 0..<20 { await Task.yield() }
        store.setSceneVisible("scene", visible: true)
        XCTAssertTrue(store.visibleScenes[0].isActive)
        // Pass the original scene with an inactive bridge status; use the store's current state.
        store.recallScene(scene())
        XCTAssertEqual(store.pendingSceneID, "scene")
        for _ in 0..<80 { await Task.yield() }
        XCTAssertEqual(Set(hue.lightCommandIDs), ["lamp", "lamp-plug"])
        XCTAssertEqual(hue.commands, 2)
        XCTAssertFalse(store.visibleScenes[0].isActive)
        XCTAssertTrue(try XCTUnwrap(store.lights.first { $0.id == "other-plug" }).isOn)
        XCTAssertNil(store.pendingSceneID); XCTAssertNil(store.hueError)
        store.stop()
    }
    func testActiveSceneWithoutTargetsDoesNotRecallOrSendPowerCommands() async throws {
        let hue = FakeHue()
        hue.scenes = [HueScene(id: "scene", name: "Evening", groupID: "room", groupName: "Living", active: "static")]
        hue.lights = lights()
        let store = HomeStore(hue: hue, dyson: FakeDyson(), secrets: MemorySecrets(), persistence: MemoryConfiguration(), clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "bridge"))
        for _ in 0..<20 { await Task.yield() }
        store.setSceneVisible("scene", visible: true)
        store.recallScene(store.visibleScenes[0])
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(hue.commands, 0)
        XCTAssertTrue(hue.lightCommandIDs.isEmpty)
        XCTAssertNotNil(store.hueError)
        XCTAssertNil(store.pendingSceneID)
        XCTAssertTrue(hue.lights.first { $0.id == "other-plug" }!.isOn)
        store.stop()
    }
    func testLightOffRequestTargetsOneResourceAndHasNoGroupCommand() async throws {
        let id = "00000000-0000-4000-8000-000000000003"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = HueClient(sessionConfiguration: configuration)
        StubURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/clip/v2/resource/light/" + id)
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            XCTAssertEqual(Set(body?.keys.map { $0 } ?? []), ["on"])
            XCTAssertEqual((body?["on"] as? [String: Bool])?["on"], false)
            return (200, Data(#"{"errors":[],"data":[]}"#.utf8))
        }
        try await client.setLight(configuration: HueConfiguration(host: "hue.local", bridgeID: "001788fffe123456"), key: "test-key", id: id, on: false, brightness: nil)
    }
    func testManualChangeOverridesStaleBridgeActivity() async throws {
        let hue = FakeHue(); hue.lights = lights(); hue.lights[0].brightness = 30
        var scene = scene(); scene.active = "static"; hue.scenes = [scene]
        let store = HomeStore(hue: hue, dyson: FakeDyson(), secrets: MemorySecrets(), persistence: MemoryConfiguration(), clock: FakeClock())
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "bridge"))
        for _ in 0..<20 { await Task.yield() }
        store.setSceneVisible("scene", visible: true)
        XCTAssertFalse(store.visibleScenes[0].isActive)
        store.recallScene(scene)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(hue.commands, 1)
        XCTAssertTrue(hue.lightCommandIDs.isEmpty)
        store.stop()
    }
}
