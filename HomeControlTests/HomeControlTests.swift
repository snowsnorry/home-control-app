import XCTest
import AppKit
import Security
import CoreImage
@preconcurrency @testable import HAP
@preconcurrency import NIO
@preconcurrency import VaporHTTP
@preconcurrency import CocoaMQTT
@testable import HomeControl

final class NetworkRecoveryTests: XCTestCase {
    func testInitialPathDoesNotRestartStartupConnections() {
        var available = NetworkRecoveryPolicy()
        var unavailable = NetworkRecoveryPolicy()
        XCTAssertFalse(available.shouldRecover(isAvailable: true))
        XCTAssertFalse(unavailable.shouldRecover(isAvailable: false))
        XCTAssertTrue(unavailable.shouldRecover(isAvailable: true))
    }

    func testAvailablePathUpdatesNeverTriggerReconnect() {
        var policy = NetworkRecoveryPolicy()
        for _ in 0..<100 { XCTAssertFalse(policy.shouldRecover(isAvailable: true)) }
    }

    func testOutageTriggersOneRecoveryWhenPathReturns() {
        var policy = NetworkRecoveryPolicy()
        XCTAssertFalse(policy.shouldRecover(isAvailable: true))
        XCTAssertFalse(policy.shouldRecover(isAvailable: false))
        XCTAssertFalse(policy.shouldRecover(isAvailable: false))
        XCTAssertTrue(policy.shouldRecover(isAvailable: true))
        XCTAssertFalse(policy.shouldRecover(isAvailable: true))
        XCTAssertFalse(policy.shouldRecover(isAvailable: false))
        XCTAssertTrue(policy.shouldRecover(isAvailable: true))
    }
}

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
    func testAirflowAndOscillationMergeStateChanges() throws {
        let now = Date()
        let current = packet(#"{"msg":"CURRENT-STATE","product-state":{"fdir":"ON","oson":"OIOF","ancp":"0090","osal":"0135","osau":"0225"}}"#)
        var state = try DysonCodec.updated(DysonSnapshot(), payload: current, now: now)
        XCTAssertEqual(state.airflowDirection, .front)
        XCTAssertEqual(state.oscillation, .legacyOff)

        let change = packet(#"{"msg":"STATE-CHANGE","product-state":{"fdir":["ON","OFF"],"oson":["OIOF","OION"]}}"#)
        state = try DysonCodec.updated(state, payload: change, now: now)
        XCTAssertEqual(state.airflowDirection, .rear)
        XCTAssertEqual(state.oscillation, .legacyOn)
        XCTAssertEqual(state.oscillationProfile, "0090")
        XCTAssertEqual(state.oscillationLowerAngle, 135)
        XCTAssertEqual(state.oscillationUpperAngle, 225)
    }
    func testOscillationRangeUsesNamedPresetAndKeepsLastCenterOnStop() throws {
        let now = Date()
        let active = packet(#"{"msg":"CURRENT-STATE","product-state":{"oson":"ON","ancp":"0090","osal":"0130","osau":"0175"}}"#)
        var state = try DysonCodec.updated(DysonSnapshot(), payload: active, now: now)
        XCTAssertEqual(state.activeOscillationRange?.span, 90)
        XCTAssertEqual(state.oscillationCenter, 180)

        let stopped = packet(#"{"msg":"STATE-CHANGE","product-state":{"oson":["ON","OFF"],"ancp":"0000"}}"#)
        state = try DysonCodec.updated(state, payload: stopped, now: now)
        XCTAssertEqual(state.oscillationEnabled, false)
        XCTAssertNil(state.fixedOscillationDirection)
        XCTAssertEqual(state.oscillationCenter, 180)

        let aimed = packet(#"{"msg":"STATE-CHANGE","product-state":{"oson":"OFF","ancp":"CUST","osal":"0100","osau":"0100"}}"#)
        state = try DysonCodec.updated(state, payload: aimed, now: now)
        XCTAssertEqual(state.fixedOscillationDirection, 100)
        XCTAssertEqual(state.oscillationCenter, 100)

        let noPosition = packet(#"{"msg":"CURRENT-STATE","product-state":{"oson":"OFF","ancp":"CUST","osal":"INV"}}"#)
        state = try DysonCodec.updated(DysonSnapshot(), payload: noPosition, now: now)
        XCTAssertNil(state.oscillationCenter)
    }
    func testLocationUpdatesStoppedDirectionAndClearsWhenSweepResumes() throws {
        let now = Date()
        let sweep = packet(#"{"msg":"CURRENT-STATE","product-state":{"fpwr":"ON","oson":"ON","ancp":"CUST","osal":"0135","osau":"0225"}}"#)
        let location = packet(#"{"msg":"LOCATION","apos":"0151"}"#)
        let stop = packet(#"{"msg":"STATE-CHANGE","product-state":{"oson":["ON","OFF"]}}"#)
        var state = try DysonCodec.updated(DysonSnapshot(), payload: sweep, now: now)
        state = try DysonCodec.updated(state, payload: location, now: now)
        XCTAssertNil(state.stoppedOscillationAngle)
        XCTAssertFalse(state.canLocateStoppedPosition)

        state = try DysonCodec.updated(state, payload: stop, now: now)
        XCTAssertTrue(state.canLocateStoppedPosition)
        XCTAssertEqual(state.oscillationCenter, 180)
        state = try DysonCodec.updated(state, payload: location, now: now)
        XCTAssertEqual(state.stoppedOscillationAngle, 151)
        XCTAssertEqual(state.oscillationCenter, 151)
        XCTAssertEqual(state.oscillationLowerAngle, 135)
        XCTAssertEqual(state.oscillationUpperAngle, 225)

        let settled = packet(#"{"msg":"STATE-CHANGE","product-state":{"oscs":["ON","OFF"]}}"#)
        state = try DysonCodec.updated(state, payload: settled, now: now)
        let invalid = packet(#"{"msg":"LOCATION","apos":"0361"}"#)
        state = try DysonCodec.updated(state, payload: invalid, now: now)
        XCTAssertEqual(state.oscillationCenter, 151)

        state = try DysonCodec.updated(state, payload: sweep, now: now)
        XCTAssertNil(state.stoppedOscillationAngle)
        state = try DysonCodec.updated(state, payload: stop, now: now)
        XCTAssertEqual(state.oscillationCenter, 180)
    }
    func testOscillationLimitsKeepSpanAndSnapToDeviceTravel() {
        let left = DysonOscillationRange(center: 0, span: 45)
        XCTAssertEqual(left?.lower, 5)
        XCTAssertEqual(left?.upper, 50)
        let right = DysonOscillationRange(center: 360, span: 90)
        XCTAssertEqual(right?.lower, 265)
        XCTAssertEqual(right?.upper, 355)
        let full = DysonOscillationRange(center: 5, span: 350)
        XCTAssertEqual(full, DysonOscillationRange(center: 355, span: 350))
        XCTAssertEqual(full?.center, 180)
        XCTAssertEqual(full?.canMove, false)
        let fixed = DysonOscillationRange(center: 107, span: 0)
        XCTAssertEqual(fixed?.lower, 105)
        XCTAssertEqual(fixed?.upper, 105)
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
    var deletionFails = false
    var readFails = false
    var writeFails = false
    func read(_ account: String) throws -> String? {
        if readFails { throw ControlError.message("Keychain read failed") }
        return values[account]
    }
    func write(_ value: String, account: String) throws {
        if writeFails { throw ControlError.message("Keychain write failed") }
        values[account] = value
    }
    func delete(_ account: String) throws {
        if deletionFails { throw ControlError.authorization }
        values[account] = nil
    }
}
@MainActor final class MemoryConfiguration: ConfigurationStoreProtocol {
    var saved = SavedConfiguration()
    var fail = false
    func load() throws -> SavedConfiguration { saved }
    func save(_ value: SavedConfiguration) throws { if fail { throw ControlError.message("test failure") }; saved = value }
}
final class DysonHistoryTests: XCTestCase {
    func testParsesCloudTimeGridWithGapsAndPerMetricUnits() throws {
        let json = #"{"start_time":"2026-11-08T00:00:00+01:00","resolution":"PT15M","fnsp":[0,null,6.2,11],"p25m":[12.6,null,2],"volm":[24.8],"no2m":[7,8]}"#
        let history = try JSONDecoder().decode(DysonHistory.self, from: Data(json.utf8))
        XCTAssertEqual(history.samples.count, 4)
        XCTAssertEqual(history.samples[0].date.ISO8601Format(), "2026-11-07T23:00:00Z")
        XCTAssertEqual(history.samples[1].date.timeIntervalSince(history.samples[0].date), 900)
        XCTAssertEqual(history.samples[0].speed, 0)
        XCTAssertEqual(history.samples[0].pollutants[.pm25], 12.6)
        XCTAssertEqual(history.samples[0].pollutants[.voc] ?? -1, 2.48, accuracy: 0.001)
        XCTAssertEqual(history.samples[1].pollutants[.nitrogenDioxide], 0.8)
        XCTAssertNil(history.samples[1].speed)
        XCTAssertEqual(history.samples[2].speed, 6.2)
        XCTAssertFalse(history.samples[3].hasReadings)
    }

    func testRejectsUnknownResolution() {
        let json = #"{"start_time":"2026-11-08T00:00:00Z","resolution":"PT1H","fnsp":[1]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(DysonHistory.self, from: Data(json.utf8)))
    }
}

@MainActor final class DysonHistoryStoreTests: XCTestCase {
    private final class Client: DysonHistoryClientProtocol {
        var failure: DysonHistoryHTTPError?
        var requests: [(serial: String, token: String)] = []
        var beforeReply: (() -> Void)?
        func fetchHistory(serial: String, token: String) async throws -> DysonHistory {
            requests.append((serial, token))
            beforeReply?()
            if let failure { throw failure }
            return DysonHistory(samples: [.init(date: Date(timeIntervalSince1970: 0), pollutants: [.voc: 2], speed: 7)])
        }
        func reset() {}
    }

    func testMyDysonSetupSessionOpensHistoryAcrossLaunchesWithoutAnotherCode() async throws {
        let secrets = MemorySecrets(), config = MemoryConfiguration(), client = Client(), clock = FakeClock()
        let store = HomeStore(hue: FakeHue(), dyson: FakeDyson(), secrets: secrets, persistence: config, clock: clock,
                              historyClient: client)
        defer { store.stop() }
        let purifier = DysonConfiguration(host: "dyson.local", serial: "TEST-123", topicPrefix: "438", name: "Dyson")
        try MyDysonSessions(secrets: secrets).save("setup-token", for: purifier.serial)
        try await store.connectDyson(purifier, credential: "local-key")
        XCTAssertEqual(secrets.values["dyson-history:TEST-123"], "setup-token")
        XCTAssertEqual(secrets.values["dyson"], "local-key")

        let reopened = DysonHistoryStore(client: client, secrets: secrets, clock: clock)
        try reopened.selectDevice(config.saved.dyson?.serial)
        reopened.open()
        await finish(reopened)
        XCTAssertEqual(client.requests.last?.token, "setup-token")
        XCTAssertEqual(reopened.data?.samples.first?.speed, 7)
        XCTAssertNil(reopened.error)
    }

    func testMissingSessionDoesNotRequestHistoryAndPicksUpLaterLogin() async throws {
        let client = Client(), secrets = MemorySecrets()
        let store = DysonHistoryStore(client: client, secrets: secrets, clock: FakeClock())
        try store.selectDevice("TEST-123")
        store.open()
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertNotNil(store.error)
        // A normal or diagnostic login can happen after the popover was first opened.
        try MyDysonSessions(secrets: secrets).save("account-token", for: "TEST-123")
        store.open()
        await finish(store)
        XCTAssertEqual(client.requests.last?.token, "account-token")
        XCTAssertNotNil(store.data)
        XCTAssertNil(store.error)
    }

    func testTransientFailureRetainsSessionAndRefreshRetries() async throws {
        let client = Client(), secrets = MemorySecrets()
        try MyDysonSessions(secrets: secrets).save("account-token", for: "TEST-123")
        let store = DysonHistoryStore(client: client, secrets: secrets, clock: FakeClock())
        try store.selectDevice("TEST-123")
        client.failure = DysonHistoryHTTPError(status: 503)
        store.open()
        await finish(store)
        XCTAssertNil(store.data)
        XCTAssertEqual(try MyDysonSessions(secrets: secrets).read(for: "TEST-123"), "account-token")
        client.failure = nil
        store.refresh()
        await finish(store)
        XCTAssertNotNil(store.data)
        XCTAssertNil(store.error)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testOpeningCachedHistoryDoesNotRefetchButRefreshDoes() async throws {
        let client = Client(), secrets = MemorySecrets(), clock = FakeClock()
        try MyDysonSessions(secrets: secrets).save("account-token", for: "TEST-123")
        let store = DysonHistoryStore(client: client, secrets: secrets, clock: clock)
        try store.selectDevice("TEST-123")
        store.open()
        await finish(store)
        store.open()
        await finish(store)
        XCTAssertEqual(client.requests.count, 1)
        store.refresh()
        await finish(store)
        XCTAssertEqual(client.requests.count, 2)
        clock.now.addTimeInterval(301)
        store.open()
        await finish(store)
        XCTAssertEqual(client.requests.count, 3)
    }

    func testExpiredSessionPreservesReadingsAndDoesNotDeleteNewerLogin() async throws {
        let client = Client(), secrets = MemorySecrets()
        let sessions = MyDysonSessions(secrets: secrets)
        try sessions.save("old-token", for: "TEST-123")
        let store = DysonHistoryStore(client: client, secrets: secrets, clock: FakeClock())
        try store.selectDevice("TEST-123")
        store.open()
        await finish(store)
        client.failure = DysonHistoryHTTPError(status: 401)
        client.beforeReply = { try! sessions.save("new-token", for: "TEST-123") }
        store.refresh()
        await finish(store)
        XCTAssertEqual(store.data?.samples.first?.speed, 7)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try sessions.read(for: "TEST-123"), "new-token")
        client.beforeReply = nil
        client.failure = nil
        store.open()
        await finish(store)
        XCTAssertEqual(client.requests.last?.token, "new-token")
        XCTAssertNil(store.error)
    }

    func testRejectedSessionIsNotRetriedAndDoesNotTouchSharedCredentials() async throws {
        let client = Client(), secrets = MemorySecrets()
        secrets.values["dyson-history:TEST-123"] = "expired"
        secrets.values["dyson"] = "local-key"
        client.failure = DysonHistoryHTTPError(status: 401)
        let store = DysonHistoryStore(client: client, secrets: secrets, clock: FakeClock())
        try store.selectDevice("TEST-123")
        store.open()
        await finish(store)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(secrets.values["dyson-history:TEST-123"], "expired")
        XCTAssertEqual(secrets.values["dyson"], "local-key")
        store.open()
        XCTAssertEqual(client.requests.count, 1)
    }

    func testKeychainReadFailureCanRetryAndDeviceChangeClearsPreviousData() async throws {
        let client = Client(), secrets = MemorySecrets()
        secrets.values["dyson-history:TEST-123"] = "first-token"
        secrets.values["dyson-history:TEST-456"] = "second-token"
        let store = DysonHistoryStore(client: client, secrets: secrets, clock: FakeClock())
        try store.selectDevice("TEST-123")
        secrets.readFails = true
        store.open()
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertNotNil(store.error)
        secrets.readFails = false
        store.refresh()
        await finish(store)
        XCTAssertNotNil(store.data)
        try store.selectDevice("TEST-456")
        XCTAssertNil(store.data)
        XCTAssertNil(secrets.values["dyson-history:TEST-123"])
        store.open()
        await finish(store)
        XCTAssertEqual(client.requests.last?.serial, "TEST-456")
        XCTAssertEqual(client.requests.last?.token, "second-token")
    }

    private func finish(_ store: DysonHistoryStore) async {
        for _ in 0..<200 where store.isBusy { await Task.yield() }
        XCTAssertFalse(store.isBusy)
    }
}

@MainActor final class ConnectionWizardSessionTests: XCTestCase {
    private final class Cloud: CloudDysonClientProtocol {
        var delayNext = false
        var pending: CheckedContinuation<Void, Error>?
        var saveFails = true
        var devices: [CloudDysonDevice] = []
        var didVerify: (() throws -> Void)?
        var verifyArguments: [(code: String, password: String)] = []
        func requestCode(email: String, country: String) async throws {}
        func reset() {}
        func verify(code: String, password: String) async throws -> (token: String, devices: [CloudDysonDevice]) {
            verifyArguments.append((code, password))
            if delayNext {
                delayNext = false
                try await withCheckedThrowingContinuation { pending = $0 }
            }
            if saveFails { throw MyDysonSessionSaveError() }
            try didVerify?()
            return ("test-token", devices)
        }
    }

    func testSaveRetryRemainsAvailableAfterClearingPasswordAndCode() async {
        let cloud = Cloud()
        let retryWizard = ConnectionWizard(cloud: cloud)
        retryWizard.password = "test-password"
        retryWizard.code = "123456"
        retryWizard.codeSent = true
        retryWizard.verify()
        await finish(retryWizard)
        XCTAssertTrue(retryWizard.sessionSavePending)
        XCTAssertTrue(retryWizard.password.isEmpty)
        XCTAssertTrue(retryWizard.code.isEmpty)
        cloud.saveFails = false
        retryWizard.verify()
        await finish(retryWizard)
        XCTAssertFalse(retryWizard.sessionSavePending)
        XCTAssertEqual(cloud.verifyArguments.count, 2)
        XCTAssertEqual(cloud.verifyArguments.last?.password, "")
        XCTAssertEqual(cloud.verifyArguments.last?.code, "")
        retryWizard.cancel()
    }

    func testCancelledVerificationCannotChangeNewFlowsSaveRetryState() async {
        let cloud = Cloud()
        cloud.delayNext = true
        let wizard = ConnectionWizard(cloud: cloud)
        wizard.verify()
        for _ in 0..<100 where cloud.pending == nil { await Task.yield() }
        XCTAssertNotNil(cloud.pending)
        wizard.cancel()
        wizard.verify()
        await finish(wizard)
        XCTAssertTrue(wizard.sessionSavePending)
        cloud.pending?.resume(throwing: ControlError.authorization)
        cloud.pending = nil
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(wizard.sessionSavePending)
        wizard.cancel()
    }

    private final class History: DysonHistoryClientProtocol {
        var failure: Int?
        var failuresByToken: [String: Int] = [:]
        var tokens: [String] = []
        var delay = false
        var pending: CheckedContinuation<Void, Never>?
        func reset() {}
        func fetchHistory(serial: String, token: String) async throws -> DysonHistory {
            tokens.append(token)
            let responseFailure = failuresByToken[token] ?? failure
            if delay { await withCheckedContinuation { pending = $0 } }
            if let responseFailure { throw DysonHistoryHTTPError(status: responseFailure) }
            return DysonHistory(samples: [.init(date: Date(timeIntervalSince1970: 0), pollutants: [.voc: 2], speed: 8)])
        }
    }

    private func recoveryFixture() -> (HomeStore, ConnectionWizard, Cloud, History, MemorySecrets) {
        let secrets = MemorySecrets(), config = MemoryConfiguration(), history = History(), cloud = Cloud()
        config.saved.dyson = DysonConfiguration(host: "dyson.local", serial: "TEST-123", topicPrefix: "438", name: "Dyson")
        secrets.values["dyson"] = "local-key"
        cloud.saveFails = false
        cloud.devices = [CloudDysonDevice(serial: "TEST-123", name: "Dyson", topicPrefix: "438", credential: "local-key")]
        cloud.didVerify = { try MyDysonSessions(secrets: secrets).save("test-token", for: "TEST-123") }
        let store = HomeStore(hue: FakeHue(), dyson: FakeDyson(), secrets: secrets, persistence: config,
                              clock: FakeClock(), historyClient: history)
        let wizard = ConnectionWizard(cloud: cloud)
        wizard.selected = .dyson
        return (store, wizard, cloud, history, secrets)
    }

    func testReconnectRestoresMissingAccountThenLoadsHistoryWithoutRepeatingDeviceSetup() async throws {
        let (store, wizard, cloud, history, secrets) = recoveryFixture()
        defer { wizard.cancel(); store.stop() }
        let original = store.configuration.dyson
        wizard.reconnect(store: store)
        await finish(wizard)
        XCTAssertTrue(wizard.active)
        XCTAssertTrue(wizard.recoveringDysonAccount)
        XCTAssertTrue(cloud.verifyArguments.isEmpty)
        XCTAssertTrue(history.tokens.isEmpty)
        XCTAssertEqual(store.configuration.dyson, original)
        wizard.password = "test-password"
        wizard.code = "123456"
        wizard.codeSent = true
        wizard.verify(store: store)
        await finish(wizard)
        XCTAssertFalse(wizard.active)
        XCTAssertFalse(wizard.recoveringDysonAccount)
        XCTAssertTrue(wizard.success)
        XCTAssertNil(wizard.error)
        XCTAssertEqual(store.dysonHistory.data?.samples.first?.speed, 8)
        XCTAssertEqual(history.tokens, ["test-token"])
        XCTAssertEqual(store.configuration.dyson, original)
        XCTAssertEqual(secrets.values["dyson"], "local-key")
        XCTAssertTrue(wizard.password.isEmpty)
        XCTAssertTrue(wizard.code.isEmpty)
    }

    func testReconnectWithSavedSessionLoadsHistoryWithoutOpeningLogin() async throws {
        let (store, wizard, cloud, history, secrets) = recoveryFixture()
        defer { wizard.cancel(); store.stop() }
        secrets.values["dyson-history:TEST-123"] = "saved-token"
        wizard.reconnect(store: store)
        await finish(wizard)
        XCTAssertFalse(wizard.active)
        XCTAssertFalse(wizard.recoveringDysonAccount)
        XCTAssertTrue(cloud.verifyArguments.isEmpty)
        XCTAssertEqual(history.tokens, ["saved-token"])
        XCTAssertNotNil(store.dysonHistory.data)
    }

    func testReconnectRoutesRejectedSessionToRecoveryButNotServiceOrKeychainErrors() async throws {
        let (store, wizard, _, history, secrets) = recoveryFixture()
        defer { wizard.cancel(); store.stop() }
        secrets.values["dyson-history:TEST-123"] = "saved-token"
        history.failure = 503
        wizard.reconnect(store: store)
        await finish(wizard)
        XCTAssertFalse(wizard.active)
        XCTAssertFalse(store.dysonHistory.needsAccountConnection)
        XCTAssertNotNil(store.dysonHistory.error)
        history.failure = nil
        secrets.readFails = true
        wizard.reconnect(store: store)
        await finish(wizard)
        XCTAssertFalse(wizard.active)
        XCTAssertFalse(store.dysonHistory.needsAccountConnection)
        secrets.readFails = false
        history.failure = 401
        wizard.reconnect(store: store)
        await finish(wizard)
        XCTAssertTrue(wizard.active)
        XCTAssertTrue(wizard.recoveringDysonAccount)
        XCTAssertEqual(secrets.values["dyson"], "local-key")
    }

    func testRecoveryRejectsDifferentAccountWithoutReplacingConnectedDevice() async {
        let (store, wizard, cloud, history, secrets) = recoveryFixture()
        defer { wizard.cancel(); store.stop() }
        let original = store.configuration.dyson
        wizard.reconnect(store: store)
        await finish(wizard)
        cloud.devices = [CloudDysonDevice(serial: "OTHER", name: "Other", topicPrefix: "438", credential: "other-key")]
        cloud.didVerify = nil
        wizard.verify(store: store)
        await finish(wizard)
        XCTAssertTrue(wizard.active)
        XCTAssertTrue(wizard.recoveringDysonAccount)
        XCTAssertNotNil(wizard.error)
        XCTAssertFalse(wizard.success)
        XCTAssertTrue(history.tokens.isEmpty)
        XCTAssertEqual(store.configuration.dyson, original)
        XCTAssertEqual(secrets.values["dyson"], "local-key")
    }

    func testCancelledReconnectDoesNotOpenRecoveryAfterLateHistoryFailure() async {
        let (store, wizard, _, history, secrets) = recoveryFixture()
        defer { wizard.cancel(); store.stop() }
        secrets.values["dyson-history:TEST-123"] = "saved-token"
        history.delay = true
        history.failure = 401
        wizard.reconnect(store: store)
        for _ in 0..<200 where history.pending == nil { await Task.yield() }
        XCTAssertNotNil(history.pending)
        wizard.cancel()
        wizard.showsGeneral = true
        history.pending?.resume()
        history.pending = nil
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(wizard.active)
        XCTAssertFalse(wizard.recoveringDysonAccount)
        XCTAssertTrue(wizard.showsGeneral)
    }

    func testReconnectRereadsNewSessionAfterOlderInFlightRequestFails() async {
        let (store, wizard, cloud, history, secrets) = recoveryFixture()
        defer { wizard.cancel(); store.stop() }
        secrets.values["dyson-history:TEST-123"] = "old-token"
        history.delay = true
        history.failuresByToken["old-token"] = 401
        store.dysonHistory.open()
        for _ in 0..<200 where history.pending == nil { await Task.yield() }
        XCTAssertNotNil(history.pending)
        secrets.values["dyson-history:TEST-123"] = "new-token"
        wizard.reconnect(store: store)
        for _ in 0..<20 { await Task.yield() }
        history.delay = false
        history.pending?.resume()
        history.pending = nil
        await finish(wizard)
        XCTAssertEqual(history.tokens, ["old-token", "new-token"])
        XCTAssertNotNil(store.dysonHistory.data)
        XCTAssertNil(store.dysonHistory.error)
        XCTAssertFalse(wizard.active)
        XCTAssertFalse(wizard.recoveringDysonAccount)
        XCTAssertTrue(cloud.verifyArguments.isEmpty)
    }

    func testPostRecoveryHistoryFailureIsNotCopiedIntoWizardAndClearsOnRetry() async throws {
        let (store, wizard, _, history, _) = recoveryFixture()
        defer { wizard.cancel(); store.stop() }
        wizard.reconnect(store: store)
        await finish(wizard)
        history.failure = 503
        wizard.verify(store: store)
        await finish(wizard)
        XCTAssertFalse(wizard.active)
        XCTAssertFalse(wizard.success)
        XCTAssertNil(wizard.error)
        XCTAssertNotNil(store.dysonHistory.error)
        history.failure = nil
        try await store.dysonHistory.refreshAndWait()
        XCTAssertNotNil(store.dysonHistory.data)
        XCTAssertNil(store.dysonHistory.error)
        XCTAssertNil(wizard.error)
    }

    private func finish(_ wizard: ConnectionWizard) async {
        for _ in 0..<200 where wizard.busy { await Task.yield() }
        XCTAssertFalse(wizard.busy)
    }
}

@MainActor final class FakeClock: AppClock {
    var now = Date(timeIntervalSince1970: 0)
    var advancesAutomatically = true
    func sleep(seconds: Double) async throws {
        if advancesAutomatically { now = now.addingTimeInterval(seconds) }
        await Task.yield()
        try Task.checkCancellation()
    }
}
@MainActor final class FakeHue: HueClientProtocol {
    var lights: [HueLight] = []
    var commands = 0
    var watches = 0
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
    func watch(configuration: HueConfiguration, key: String, changed: @escaping @MainActor () async -> Void) async throws { watches += 1; try await Task.sleep(for: .seconds(1000)) }
}
@MainActor final class FakeDyson: DysonClientProtocol {
    var onSnapshot: (@MainActor (DysonSnapshot) -> Void)?
    var onConnection: (@MainActor (ConnectionState, String?) -> Void)?
    var commands: [[String: String]] = []
    var snapshot = DysonSnapshot()
    var confirm = true
    var connections = 0
    var disconnections = 0
    func connect(configuration: DysonConfiguration, credential: String) async throws { connections += 1; onSnapshot?(snapshot); onConnection?(.online, nil) }
    func disconnect() { disconnections += 1; onConnection?(.offline, nil) }
    func requestSensors() { }
    func command(_ fields: [String: String]) throws {
        commands.append(fields)
        if confirm {
            var state = fields
            if let lower = fields["osal"], lower == fields["osau"],
               let mode = fields["oson"].flatMap(DysonOscillation.init(rawValue:)) {
                state["oson"] = mode.setting(false).rawValue
            }
            try receiveState(state)
        }
    }
    func receiveState(_ fields: [String: String]) throws {
        let now = Date()
        let reply = try DysonCodec.encode(message: "STATE-CHANGE", additional: ["product-state": fields], now: now)
        snapshot = try DysonCodec.updated(snapshot, payload: Data(reply.utf8), now: now)
        onSnapshot?(snapshot)
    }
}
@MainActor final class StoreTests: XCTestCase {
    func testNetworkRecoveryPreservesHealthyDeviceConnections() async throws {
        let (store, hue, dyson, _, _, _) = fixture()
        try await store.connectHue(HueConfiguration(host: "hue.local", bridgeID: "001788fffe123456"))
        try await store.connectDyson(DysonConfiguration(host: "dyson.local", serial: "TEST-123", topicPrefix: "438", name: "Test Dyson"), credential: "test-key")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.hueState, .online)
        XCTAssertEqual(store.dysonState, .online)
        let connections = dyson.connections, disconnections = dyson.disconnections
        let watches = hue.watches
        for _ in 0..<10 { store.recoverConnectionsAfterNetworkChange() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.hueState, .online)
        XCTAssertEqual(store.dysonState, .online)
        XCTAssertEqual(dyson.connections, connections)
        XCTAssertEqual(dyson.disconnections, disconnections)
        XCTAssertEqual(hue.watches, watches)
        store.stop()
    }

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
    func testAirflowAndOscillationCommandConfirmation() async throws {
        let (store, _, client, _, _, _) = fixture()
        client.snapshot.isOn = true
        client.snapshot.airflowDirection = .front
        client.snapshot.oscillation = .legacyOff
        client.snapshot.oscillationProfile = "0090"
        client.snapshot.oscillationLowerAngle = 135
        client.snapshot.oscillationUpperAngle = 225
        try await store.connectDyson(DysonConfiguration(host: "dyson.local", serial: "ABC-123", topicPrefix: "438M", name: "Dyson"), credential: "credential")
        defer { store.stop() }

        store.setDyson(["fdir": "OFF"])
        for _ in 0..<100 where store.dysonPending { await Task.yield() }
        XCTAssertEqual(client.commands.last, ["fdir": "OFF"])
        XCTAssertEqual(store.dyson.airflowDirection, .rear)
        XCTAssertFalse(store.dysonPending)
        XCTAssertNil(store.dysonError)

        store.setDysonOscillationRange(center: 180, span: 90)
        for _ in 0..<100 where store.dysonPending { await Task.yield() }
        XCTAssertEqual(client.commands.last, ["oson": "OION", "ancp": "CUST", "osal": "0135", "osau": "0225"])
        XCTAssertEqual(store.dyson.oscillation, .legacyOn)
        XCTAssertFalse(store.dysonPending)
        XCTAssertNil(store.dysonError)

        store.stopDysonOscillation()
        for _ in 0..<100 where store.dysonPending { await Task.yield() }
        XCTAssertEqual(client.commands.last, ["oson": "OIOF"])
        XCTAssertEqual(store.dyson.oscillation, .legacyOff)
        XCTAssertEqual(store.dyson.oscillationCenter, 180)
        XCTAssertNil(store.dyson.fixedOscillationDirection)
        XCTAssertFalse(store.dysonPending)
        XCTAssertNil(store.dysonError)

        store.setDysonOscillationRange(center: 107, span: 0)
        XCTAssertEqual(store.dysonPendingOscillationRange?.center, 105)
        XCTAssertEqual(store.dyson.oscillationCenter, 180)
        for _ in 0..<100 where store.dysonPending { await Task.yield() }
        XCTAssertEqual(client.commands.last, ["oson": "OION", "ancp": "CUST", "osal": "0105", "osau": "0105"])
        XCTAssertEqual(store.dyson.fixedOscillationDirection, 105)
        XCTAssertEqual(store.dyson.oscillationEnabled, false)
        XCTAssertNil(store.dysonPendingOscillationRange)
        XCTAssertFalse(store.dysonPending)
        XCTAssertNil(store.dysonError)
    }
    func testOscillationRangeRequiresMatchingBoundsAndReportsTimeoutOrDisconnect() async throws {
        let (store, _, client, _, _, clock) = fixture()
        clock.advancesAutomatically = false
        client.snapshot.isOn = true
        client.snapshot.oscillation = .on
        client.snapshot.oscillationProfile = "CUST"
        client.snapshot.oscillationLowerAngle = 135
        client.snapshot.oscillationUpperAngle = 225
        client.confirm = false
        try await store.connectDyson(DysonConfiguration(host: "dyson.local", serial: "ABC-123", topicPrefix: "438", name: "Dyson"), credential: "credential")
        defer { store.stop() }

        store.setDysonOscillationRange(center: 180, span: 180)
        store.stopDysonOscillation()
        for _ in 0..<30 where client.commands.isEmpty { await Task.yield() }
        XCTAssertEqual(client.commands, [["oson": "ON", "ancp": "CUST", "osal": "0090", "osau": "0270"]])
        try client.receiveState(["oson": "ON", "ancp": "CUST", "osal": "0135", "osau": "0225"])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(store.dysonPending)
        XCTAssertEqual(store.dysonPendingOscillationRange?.span, 180)

        try client.receiveState(["osal": "0090", "osau": "0270"])
        for _ in 0..<30 where store.dysonPending { await Task.yield() }
        XCTAssertFalse(store.dysonPending)
        XCTAssertNil(store.dysonPendingOscillationRange)
        XCTAssertEqual(store.dyson.activeOscillationRange?.span, 180)

        store.setDysonOscillationRange(center: 180, span: 90)
        for _ in 0..<30 where client.commands.count < 2 { await Task.yield() }
        clock.now = clock.now.addingTimeInterval(11)
        for _ in 0..<30 where store.dysonPending { await Task.yield() }
        XCTAssertEqual(store.dysonError, ControlError.timeout.localizedDescription)
        XCTAssertNil(store.dysonPendingOscillationRange)
        XCTAssertEqual(store.dyson.activeOscillationRange?.span, 180)

        store.setDysonOscillationRange(center: 200, span: 180)
        XCTAssertEqual(store.dysonPendingOscillationRange?.center, 200)
        for _ in 0..<30 where client.commands.count < 3 { await Task.yield() }
        client.onConnection?(.offline, nil)
        XCTAssertFalse(store.dysonPending)
        XCTAssertNil(store.dysonPendingOscillationRange)
        XCTAssertEqual(store.dysonError, ControlError.offline.localizedDescription)
        XCTAssertFalse(store.canAdjustDysonOscillation)
    }
    func testOscillationPresetAcceptsReportedSpanWithDifferentProfileOrBounds() async throws {
        let (store, _, client, _, _, clock) = fixture()
        clock.advancesAutomatically = false
        client.snapshot.isOn = true
        client.snapshot.oscillation = .off
        client.snapshot.oscillationProfile = "CUST"
        client.snapshot.oscillationLowerAngle = 180
        client.snapshot.oscillationUpperAngle = 180
        client.confirm = false
        try await store.connectDyson(DysonConfiguration(host: "dyson.local", serial: "ABC-123", topicPrefix: "438", name: "Dyson"), credential: "credential")
        defer { store.stop() }

        store.selectDysonOscillationSpan(45)
        for _ in 0..<30 where client.commands.isEmpty { await Task.yield() }
        try client.receiveState(["oson": "ON", "ancp": "0090"])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(store.dysonPending)
        try client.receiveState(["ancp": "0045"])
        for _ in 0..<30 where store.dysonPending { await Task.yield() }
        XCTAssertFalse(store.dysonPending)
        XCTAssertEqual(store.dyson.activeOscillationRange?.span, 45)
        XCTAssertNil(store.dysonError)

        store.selectDysonOscillationSpan(90)
        for _ in 0..<30 where client.commands.count < 2 { await Task.yield() }
        XCTAssertNotEqual(client.commands.last?["osal"], "0130")
        try client.receiveState(["ancp": "CUST", "osal": "0130", "osau": "0220"])
        for _ in 0..<30 where store.dysonPending { await Task.yield() }
        XCTAssertFalse(store.dysonPending)
        XCTAssertEqual(store.dyson.activeOscillationRange?.span, 90)
        XCTAssertNil(store.dysonError)
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
    func client(secrets: MemorySecrets = MemorySecrets()) -> MyDysonClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return MyDysonClient(sessionConfiguration: config, secrets: secrets)
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
        let secrets = MemorySecrets()
        // Use one persisted session across distinct clients, as setup and history do.
        let login = client(secrets: secrets)
        try await login.requestCode(email: "test@example.com", country: "CZ")
        let session = try await login.verify(code: "123456", password: "test-password")
        XCTAssertEqual(session.devices.count, 1)
        XCTAssertEqual(session.token, "test-token")
        XCTAssertEqual(try MyDysonSessions(secrets: secrets).read(for: "ABC-123"), "test-token")
        do { _ = try await login.verify(code: "123456", password: "test-password"); XCTFail("Challenge must be cleared") } catch { }
        // From this point any second login request fails the test.
        StubURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/v1/messageprocessor/devices/ABC-123/environmentdata/daily")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, Data(#"{"start_time":"2026-11-08T00:00:00Z","resolution":"PT15M","volm":[20],"fnsp":[7]}"#.utf8))
        }
        let history = DysonHistoryStore(client: client(secrets: secrets), secrets: secrets, clock: FakeClock())
        try history.selectDevice("ABC-123")
        history.open()
        for _ in 0..<100 where history.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(history.error)
        XCTAssertEqual(history.data?.samples.first?.speed, 7)
        XCTAssertEqual(history.data?.samples.first?.pollutants[.voc], 2)
    }
    func testFailedSessionSaveRetriesWithoutAnotherAuthenticationRequest() async throws {
        let encrypted = encrypted
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/v1/provisioningservice/application/Android/version": return (200, Data())
            case "/v3/userregistration/email/userstatus": return (200, Data(#"{"accountStatus":"ACTIVE"}"#.utf8))
            case "/v3/userregistration/email/auth": return (200, Data(#"{"challengeId":"challenge"}"#.utf8))
            case "/v3/userregistration/email/verify": return (200, Data(#"{"token":"test-token"}"#.utf8))
            case "/v2/provisioningservice/manifest":
                return (200, Data("[{\"Serial\":\"ABC-123\",\"ProductType\":\"438M\",\"LocalCredentials\":\"\(encrypted)\"}]".utf8))
            default: return (404, Data())
            }
        }
        let secrets = MemorySecrets()
        let savingLogin = client(secrets: secrets)
        secrets.writeFails = true
        try await savingLogin.requestCode(email: "test@example.com", country: "CZ")
        do {
            _ = try await savingLogin.verify(code: "123456", password: "test-password")
            XCTFail("A failed save must be reported")
        } catch { XCTAssertTrue(error is MyDysonSessionSaveError) }
        XCTAssertNil(secrets.values["dyson-history:ABC-123"])
        StubURLProtocol.install { _ in
            XCTFail("Retrying a verified session must not send any HTTP request")
            return (500, Data())
        }
        secrets.writeFails = false
        let session = try await savingLogin.verify(code: "", password: "")
        XCTAssertEqual(session.token, "test-token")
        XCTAssertEqual(try MyDysonSessions(secrets: secrets).read(for: "ABC-123"), "test-token")
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
        for (keyPath, boundaries) in [(\DysonSnapshot.pm25, [36.0, 54, 71, 151, 251]), (\DysonSnapshot.pm10, [51.0, 76, 101, 351, 421]),
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
    func testHighGasIndexCannotMaskHigherParticleBand() {
        var snapshot = DysonSnapshot()
        snapshot.voc = SensorReading(value: 100, receivedAt: now)
        snapshot.nitrogenDioxide = SensorReading(value: 100, receivedAt: now)
        snapshot.pm25 = SensorReading(value: 151, receivedAt: now)
        XCTAssertEqual(snapshot.airQuality(at: now, connected: true), .extremelyPoor)
        XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, .pm25)
        snapshot.pm10 = SensorReading(value: 421, receivedAt: now)
        XCTAssertEqual(snapshot.airQuality(at: now, connected: true), .severe)
        XCTAssertEqual(snapshot.dominantPollutant(at: now)?.pollutant, .pm10)
        snapshot.pm25 = nil
        snapshot.pm10 = nil
        XCTAssertEqual(snapshot.airQuality(at: now, connected: true), .veryPoor)
    }
    func testIndividualPollutantQuality() {
        for pollutant in DysonPollutant.allCases {
            XCTAssertEqual(pollutant.quality(for: 0), .good)
            for (index, boundary) in pollutant.boundaries.enumerated() {
                XCTAssertEqual(pollutant.quality(for: boundary - 0.01)?.rawValue, index)
                XCTAssertEqual(pollutant.quality(for: boundary)?.rawValue, index + 1)
            }
            for invalid in [-1.0, .nan, .infinity] {
                XCTAssertNil(pollutant.quality(for: invalid))
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
        XCTAssertFalse(presentation.closeDetailPopover())
        presentation.showsPollutants = true
        XCTAssertTrue(presentation.closeDetailPopover())
        XCTAssertFalse(presentation.showsPollutants)
        presentation.showsDysonOscillation = true
        XCTAssertTrue(presentation.closeDetailPopover())
        XCTAssertFalse(presentation.showsDysonOscillation)
        presentation.selectedLight = .init(id: "lamp")
        XCTAssertTrue(presentation.closeDetailPopover()); XCTAssertNil(presentation.selectedLight)
        XCTAssertFalse(presentation.closeDetailPopover())
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
    func testTallScreenStartsWithAllContentVisibleAndStillAllowsResizing() {
        let limits = PanelHeightLimits(contentHeight: 920, availableHeight: 1400)
        XCTAssertEqual(limits.height(preferred: nil), 932)
        XCTAssertEqual(limits.maximum, 932)
        XCTAssertTrue(limits.canResize)
        XCTAssertEqual(limits.height(preferred: 2000), 932)
        XCTAssertEqual(limits.height(preferred: 300), 700)
    }
    func testContentJustAboveOldDefaultDoesNotClipDysonOnLaunch() {
        let limits = PanelHeightLimits(contentHeight: 716, availableHeight: 1000)
        XCTAssertEqual(limits.height(preferred: nil), 728)
        XCTAssertEqual(limits.height(preferred: 700), 700)
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
        XCTAssertEqual(limits.height(preferred: nil), 1080)
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

@MainActor final class FakeDysonHomeKitServer: DysonHomeKitServerProtocol {
    var onStatus: (@MainActor (DysonHomeKitStatus) -> Void)?
    var onControl: (@MainActor (DysonHomeCommand) async throws -> Void)?
    var starts = 0
    var stops = 0
    var resets = 0
    var readings: [(DysonSnapshot, Bool, Date)] = []
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func reset() { resets += 1 }
    func update(_ snapshot: DysonSnapshot, connected: Bool, now: Date) { readings.append((snapshot, connected, now)) }
}

final class MemoryHomeKitIdentity: HomeKitSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var failLoad = false
    var failSave = false
    var failDelete = false
    var saves = 0
    func load() throws -> Data? {
        try lock.withLock { if failLoad { throw HomeKitStorageError.missingConfiguration }; return stored }
    }
    func save(_ data: Data) throws {
        try lock.withLock { if failSave { throw HomeKitStorageError.missingConfiguration }; stored = data; saves += 1 }
    }
    func delete() throws {
        try lock.withLock { if failDelete { throw HomeKitStorageError.missingConfiguration }; stored = nil }
    }
}

@MainActor private final class FakeHomeKitBonjourMonitor: HomeKitBonjourMonitoring {
    private(set) var starts = 0
    private(set) var stops = 0
    private var completion: (@MainActor (String?) -> Void)?
    func start(identifier: String, completion: @escaping @MainActor (String?) -> Void) {
        starts += 1; self.completion = completion
    }
    func stop() { stops += 1; completion = nil }
    func finish(error: String?) { completion?(error) }
}

@MainActor private final class HomeKitBonjourProbe: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    let identifier: String
    private(set) var found = false
    init(identifier: String) { self.identifier = identifier }
    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_hap._tcp.", inDomain: "local.")
    }
    func stop() { browser.stop(); services.forEach { $0.stop() }; services = [] }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 3)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let record = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        if record["id"] == Data(identifier.utf8), sender.port > 0 { found = true }
    }
}

@MainActor final class DysonHomeKitTests: XCTestCase {
    private func sensorSnapshot(_ temperature: SensorReading?) -> DysonSnapshot {
        var snapshot = DysonSnapshot()
        snapshot.temperature = temperature
        if let date = temperature?.receivedAt {
            snapshot.humidity = SensorReading(value: 45, receivedAt: date)
            snapshot.pm25 = SensorReading(value: 10, receivedAt: date)
            snapshot.pm10 = SensorReading(value: 20, receivedAt: date)
        }
        return snapshot
    }

    private func fixture(enabled: Bool = false) -> (HomeStore, FakeDyson, FakeDysonHomeKitServer, MemoryConfiguration, FakeClock) {
        let dyson = FakeDyson(), server = FakeDysonHomeKitServer(), configuration = MemoryConfiguration(), clock = FakeClock()
        configuration.saved.dyson = DysonConfiguration(host: "dyson.local", serial: "test", topicPrefix: "438", name: "Dyson")
        configuration.saved.dysonHomeKitEnabled = enabled
        let secrets = MemorySecrets(); secrets.values["dyson"] = "dummy"
        let store = HomeStore(hue: FakeHue(), dyson: dyson, secrets: secrets, persistence: configuration, clock: clock, homeKit: server)
        return (store, dyson, server, configuration, clock)
    }
    func testBundleDeclaresTheExactFullyQualifiedBonjourTypesRequestedByNetService() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: project.appending(path: "HomeControl/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let types = try XCTUnwrap(info["NSBonjourServices"] as? [String])
        // mDNSResponder on macOS requires the literal type requested by NetService/HAP.
        for type in ["_hap._tcp.", "_hue._tcp.", "_dyson_mqtt._tcp."] {
            XCTAssertTrue(types.contains(type), "Undeclared Bonjour type: \(type)")
        }
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"] as? String)
    }
    func testBonjourFailurePreservesCodesWithoutClaimingPermissionIsDisabled() {
        let error = HomeKitBonjourMonitor.searchFailure(code: -72008, domain: 10)
        XCTAssertTrue(error.contains("-72008")); XCTAssertTrue(error.contains("10"))
        XCTAssertFalse(error.contains("Allow Home Control"))
        XCTAssertFalse(error.contains("permission"))
    }
    func testOldConfigurationDefaultsToDisabled() throws {
        let configuration = try JSONDecoder().decode(SavedConfiguration.self, from: Data(#"{"hue":null,"dyson":null}"#.utf8))
        XCTAssertNil(configuration.dysonHomeKitEnabled)
    }
    func testRenamedSharingSettingPreservesLegacyConfigurationKey() throws {
        for enabled in [false, true] {
            let legacy = Data("{\"homeKitTemperatureEnabled\":\(enabled)}".utf8)
            let configuration = try JSONDecoder().decode(SavedConfiguration.self, from: legacy)
            XCTAssertEqual(configuration.dysonHomeKitEnabled, enabled)
            let encoded = try JSONEncoder().encode(configuration)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["homeKitTemperatureEnabled"] as? Bool, enabled)
            XCTAssertNil(object["dysonHomeKitEnabled"])
        }
    }
    func testEnableDisableAndResetArePersistent() {
        let (store, _, server, configuration, _) = fixture()
        XCTAssertEqual(server.starts, 0)
        store.setDysonHomeKitEnabled(true)
        XCTAssertEqual(configuration.saved.dysonHomeKitEnabled, true)
        XCTAssertEqual(server.starts, 1)
        store.setDysonHomeKitEnabled(false)
        XCTAssertEqual(configuration.saved.dysonHomeKitEnabled, false)
        XCTAssertEqual(server.resets, 0, "Disabling must preserve pairing")
        store.resetHomeKitPairing()
        XCTAssertEqual(server.resets, 1)
        XCTAssertEqual(configuration.saved.dysonHomeKitEnabled, false)
    }
    func testFailedPreferenceSaveDoesNotStartStopOrResetServer() {
        let (store, _, server, configuration, _) = fixture()
        configuration.fail = true
        store.setDysonHomeKitEnabled(true)
        store.resetHomeKitPairing()
        XCTAssertEqual(server.starts, 0); XCTAssertEqual(server.stops, 0); XCTAssertEqual(server.resets, 0)
        XCTAssertNotNil(store.storageError)
    }
    func testSnapshotDisconnectionRecoveryAndRemoval() {
        let (store, dyson, server, configuration, clock) = fixture()
        store.setDysonHomeKitEnabled(true)
        dyson.onConnection?(.online, nil)
        var snapshot = DysonSnapshot(); snapshot.temperature = SensorReading(value: 23.4, receivedAt: clock.now)
        snapshot.humidity = SensorReading(value: 47, receivedAt: clock.now)
        snapshot.pm25 = SensorReading(value: 12, receivedAt: clock.now)
        snapshot.pm10 = SensorReading(value: 34, receivedAt: clock.now)
        snapshot.voc = SensorReading(value: 5, receivedAt: clock.now)
        snapshot.nitrogenDioxide = SensorReading(value: 7, receivedAt: clock.now)
        dyson.onSnapshot?(snapshot)
        XCTAssertEqual(server.readings.last?.0, snapshot)
        XCTAssertEqual(server.readings.last?.1, true)
        dyson.onConnection?(.offline, nil)
        XCTAssertEqual(server.readings.last?.1, false)
        dyson.onConnection?(.online, nil)
        XCTAssertEqual(server.readings.last?.1, true)
        store.remove(.dyson)
        XCTAssertEqual(configuration.saved.dysonHomeKitEnabled, false)
        XCTAssertNil(configuration.saved.dyson)
        XCTAssertEqual(server.resets, 0)
    }
    func testEnabledPreferenceRestartsOnLaunchAndNetworkChange() {
        let (store, _, server, _, _) = fixture(enabled: true)
        store.start()
        XCTAssertEqual(server.starts, 1)
        store.restartHomeKitAfterNetworkChange()
        XCTAssertEqual(server.starts, 2)
        store.stop()
        XCTAssertGreaterThanOrEqual(server.stops, 2)
    }
    func testStalenessWithoutNewMessagesIsForwardedByTimer() async {
        let (store, dyson, server, _, clock) = fixture(enabled: true)
        var snapshot = DysonSnapshot(); snapshot.temperature = SensorReading(value: 21, receivedAt: clock.now)
        dyson.snapshot = snapshot
        store.start()
        for _ in 0..<500 {
            await Task.yield()
            if server.readings.contains(where: { $0.1 && $0.2.timeIntervalSince1970 >= 120 }) { break }
        }
        store.stop()
        let stale = server.readings.first { $0.1 && $0.2.timeIntervalSince1970 >= 120 }
        XCTAssertNotNil(stale)
        if let stale { XCTAssertNil(DysonHomeKitServer.validTemperature(stale.0.temperature, connected: stale.1, now: stale.2)) }
    }
    func testAirQualityUsesAllSixLevelsAndFreshGasReadings() throws {
        XCTAssertEqual(AirQuality.allCases.map(HomeKitAirReadings.qualityValue), [1, 2, 3, 4, 5, 5])
        let now = Date(timeIntervalSince1970: 1000)
        var snapshot = sensorSnapshot(SensorReading(value: 23, receivedAt: now))
        XCTAssertEqual(HomeKitAirReadings.make(snapshot, connected: true, now: now)?.quality, 1)
        snapshot.voc = SensorReading(value: 9, receivedAt: now.addingTimeInterval(-119))
        XCTAssertEqual(HomeKitAirReadings.make(snapshot, connected: true, now: now)?.quality, 4)
        XCTAssertEqual(HomeKitAirReadings.make(snapshot, connected: true, now: now.addingTimeInterval(1))?.quality, 1)
        snapshot.voc = nil
        snapshot.nitrogenDioxide = SensorReading(value: 7, receivedAt: now)
        XCTAssertEqual(HomeKitAirReadings.make(snapshot, connected: true, now: now)?.quality, 3)
        snapshot.voc = SensorReading(value: 9, receivedAt: now.addingTimeInterval(1))
        snapshot.nitrogenDioxide = SensorReading(value: .nan, receivedAt: now)
        XCTAssertEqual(HomeKitAirReadings.make(snapshot, connected: true, now: now)?.quality, 1)
        snapshot.pm25 = SensorReading(value: 300, receivedAt: now)
        XCTAssertEqual(HomeKitAirReadings.make(snapshot, connected: true, now: now)?.quality, 5)
    }

    func testEverySharedNumericReadingMustBeValidAndFresh() {
        let now = Date(timeIntervalSince1970: 1000)
        let baseline = sensorSnapshot(SensorReading(value: 23, receivedAt: now))
        let fields: [(WritableKeyPath<DysonSnapshot, SensorReading?>, Double)] = [
            (\.temperature, 100), (\.humidity, 100), (\.pm25, 1000), (\.pm10, 1000)]
        for (field, maximum) in fields {
            for value in [0.0, maximum] {
                var snapshot = baseline
                snapshot[keyPath: field] = SensorReading(value: value, receivedAt: now)
                XCTAssertNotNil(HomeKitAirReadings.make(snapshot, connected: true, now: now))
            }
            for value in [-1.0, maximum + 0.1, Double.nan, Double.infinity] {
                var snapshot = baseline
                snapshot[keyPath: field] = SensorReading(value: value, receivedAt: now)
                XCTAssertNil(HomeKitAirReadings.make(snapshot, connected: true, now: now))
            }
            for reading: SensorReading? in [nil, SensorReading(value: nil, receivedAt: now),
                SensorReading(value: 1, receivedAt: now.addingTimeInterval(-120)),
                SensorReading(value: 1, receivedAt: now.addingTimeInterval(0.01))] {
                var snapshot = baseline; snapshot[keyPath: field] = reading
                XCTAssertNil(HomeKitAirReadings.make(snapshot, connected: true, now: now))
            }
            var snapshot = baseline
            snapshot[keyPath: field] = SensorReading(value: 1, receivedAt: now.addingTimeInterval(-119.999))
            XCTAssertNotNil(HomeKitAirReadings.make(snapshot, connected: true, now: now))
        }
        XCTAssertNil(HomeKitAirReadings.make(baseline, connected: false, now: now))
    }

    func testTemperatureOnlyPairingMigratesWithStableIIDsAndOneConfigurationIncrement() throws {
        let backing = MemoryHomeKitIdentity()
        let legacyStorage = try HomeKitIdentityStorage(backing: backing)
        let legacy = HAP.Accessory.Thermometer(info: HAP.Service.Info(name: "Dyson Temperature",
            serialNumber: "homecontrol-temperature", manufacturer: "Home Control", model: "Dyson Temperature"))
        let legacyDevice = HAP.Device(storage: legacyStorage, accessory: legacy)
        var config = try JSONSerialization.jsonObject(with: legacyStorage.read()) as! [String: Any]
        let controller = Data("synthetic-controller".utf8).base64EncodedString()
        config["pairings"] = [controller, ["identifier": controller,
            "publicKey": Data(repeating: 7, count: 32).base64EncodedString(), "role": 1]] as [Any]
        try backing.save(JSONSerialization.data(withJSONObject: config))
        let (expanded, sensor) = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        XCTAssertTrue(expanded.isPaired)
        let updated = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        for key in ["identifier", "privateKey", "setupCode", "setupKey", "pairings", "aidForAccessorySerialNumber"] {
            XCTAssertEqual(config[key] as? NSObject, updated[key] as? NSObject)
        }
        XCTAssertEqual((updated["number"] as? NSNumber)?.intValue, (config["number"] as! NSNumber).intValue + 1)
        func json(_ accessory: HAP.Accessory) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: accessory.serialized())) as! NSDictionary
        }
        sensor.reachable = true
        let oldJSON = try json(legacyDevice.accessories[0])
        let newJSON = try json(expanded.accessories[0])
        XCTAssertEqual(oldJSON["aid"] as? NSNumber, newJSON["aid"] as? NSNumber)
        let oldServices = oldJSON["services"] as! [NSDictionary]
        let newServices = newJSON["services"] as! [NSDictionary]
        // The information service changes display name/model; its IIDs and all sensor services stay stable.
        let oldInfo = oldServices[0]["characteristics"] as! [NSDictionary]
        let newInfo = newServices[0]["characteristics"] as! [NSDictionary]
        XCTAssertEqual(oldInfo.map { $0["iid"] as? NSNumber }, newInfo.map { $0["iid"] as? NSNumber })
        XCTAssertEqual(Array(newServices.prefix(oldServices.count).dropFirst()), Array(oldServices.dropFirst()))
        XCTAssertEqual(sensor.info.name.value, "Dyson TP07")
        XCTAssertEqual(sensor.info.model.value, "Dyson TP07")
        XCTAssertEqual(newServices.count, oldServices.count + 3)
        let values = HomeKitAirReadings(temperature: 23.5, humidity: 47, pm25: 12, pm10: 34, quality: 5)
        sensor.apply(values)
        let applied = try json(sensor)["services"] as! [NSDictionary]
        let characteristics = applied.flatMap { $0["characteristics"] as! [NSDictionary] }
        func characteristic(_ code: UInt32) throws -> NSDictionary {
            try XCTUnwrap(characteristics.first {
                UInt32(($0["type"] as! String).split(separator: "-")[0], radix: 16) == code
            })
        }
        let expectedCharacteristics: [(UInt32, Double, String?)] = [
            (0x11, 23.5, "celsius"), (0x10, 47, "percentage"), (0xC6, 12, nil), (0xC7, 34, nil)]
        for (code, value, unit) in expectedCharacteristics {
            let c = try characteristic(code)
            XCTAssertEqual((c["value"] as? NSNumber)?.doubleValue, value)
            XCTAssertEqual(c["unit"] as? String, unit)
            XCTAssertTrue((c["perms"] as! [String]).contains("ev"))
        }
        XCTAssertEqual((try characteristic(0x95)["value"] as? NSNumber)?.intValue, 5)
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let restarted = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        XCTAssertEqual(restarted["number"] as? NSNumber, updated["number"] as? NSNumber)
    }

    func testFailedResumeRequiresFreshInputAfterRetry() async throws {
        let backing = MemoryHomeKitIdentity()
        let discovery = FakeHomeKitBonjourMonitor()
        let server = DysonHomeKitServer(backing: backing, discovery: discovery)
        var status = DysonHomeKitStatus()
        server.onStatus = { status = $0 }
        defer { server.stop() }
        func waitFor(_ state: DysonHomeKitStatus.State) async throws {
            for _ in 0..<600 {
                if status.state == state { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Expected \(state), got \(status.state)")
        }
        server.start()
        try await waitFor(.waiting)
        let now = Date()
        let fresh = sensorSnapshot(SensorReading(value: 23, receivedAt: now))
        server.update(fresh, connected: true, now: now)
        try await waitFor(.advertising)
        discovery.finish(error: nil)
        server.update(DysonSnapshot(), connected: false, now: now)
        try await waitFor(.waiting)
        backing.failSave = true
        server.update(fresh, connected: true, now: now)
        try await waitFor(.failed)
        backing.failSave = false
        server.start()
        try await waitFor(.waiting)
        XCTAssertNil(status.readings)
        server.update(fresh, connected: true, now: now)
        try await waitFor(.advertising)
    }

    func testGasExpiryRecalculatesPublishedQualityWithoutNewMessages() async throws {
        let discovery = FakeHomeKitBonjourMonitor()
        let server = DysonHomeKitServer(backing: MemoryHomeKitIdentity(), discovery: discovery)
        var status = DysonHomeKitStatus()
        server.onStatus = { status = $0 }
        defer { server.stop() }
        server.start()
        let now = Date()
        var snapshot = sensorSnapshot(SensorReading(value: 23, receivedAt: now))
        snapshot.voc = SensorReading(value: 9, receivedAt: now.addingTimeInterval(-117))
        server.update(snapshot, connected: true, now: now)
        for _ in 0..<600 {
            if status.state == .advertising { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(status.readings?.quality, 4)
        discovery.finish(error: nil)
        for _ in 0..<600 {
            if status.readings?.quality == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(status.state, .awaitingPairing)
        XCTAssertEqual(status.readings?.quality, 1)
        XCTAssertEqual(status.readings?.temperature, 23)
        XCTAssertEqual(discovery.starts, 1)
    }

    func testTemperatureValidityAndFreshnessBoundaries() {
        let date = Date(timeIntervalSince1970: 1000)
        let reading = SensorReading(value: 20, receivedAt: date)
        XCTAssertEqual(DysonHomeKitServer.validTemperature(reading, connected: true, now: date.addingTimeInterval(119)), 20)
        XCTAssertNil(DysonHomeKitServer.validTemperature(reading, connected: true, now: date.addingTimeInterval(120)))
        XCTAssertNil(DysonHomeKitServer.validTemperature(reading, connected: false, now: date))
        XCTAssertNil(DysonHomeKitServer.validTemperature(reading, connected: true, now: date.addingTimeInterval(-1)))
        for value in [Double.nan, .infinity, -0.1, 100.1] {
            XCTAssertNil(DysonHomeKitServer.validTemperature(SensorReading(value: value, receivedAt: date), connected: true, now: date))
        }
        XCTAssertNil(DysonHomeKitServer.validTemperature(nil, connected: true, now: date))
        XCTAssertNil(DysonHomeKitServer.validTemperature(SensorReading(value: nil, receivedAt: date), connected: true, now: date))
        for value in [0.0, 100.0] {
            XCTAssertEqual(DysonHomeKitServer.validTemperature(SensorReading(value: value, receivedAt: date), connected: true, now: date), value)
        }
    }
    func testIdentitySurvivesRestartAndExplicitResetReplacesIt() throws {
        let backing = MemoryHomeKitIdentity()
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let first = try XCTUnwrap(backing.load())
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let second = try XCTUnwrap(backing.load())
        let a = try JSONSerialization.jsonObject(with: first) as! NSDictionary
        let b = try JSONSerialization.jsonObject(with: second) as! NSDictionary
        for key in ["identifier", "privateKey", "setupCode", "setupKey", "aidForAccessorySerialNumber"] {
            XCTAssertEqual(a[key] as? NSObject, b[key] as? NSObject)
        }
        try backing.delete()
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let reset = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        XCTAssertNotEqual(a["identifier"] as? String, reset["identifier"] as? String)
        XCTAssertNotEqual(a["privateKey"] as? String, reset["privateKey"] as? String)
    }
    func testLocalServerLifecycleWithSyntheticStorage() async throws {
        let backing = MemoryHomeKitIdentity()
        let discovery = FakeHomeKitBonjourMonitor()
        let server = DysonHomeKitServer(backing: backing, discovery: discovery)
        var status = DysonHomeKitStatus()
        server.onStatus = { status = $0 }
        func waitFor(_ state: DysonHomeKitStatus.State) async throws {
            for _ in 0..<600 {
                if status.state == .advertising, state == .awaitingPairing { discovery.finish(error: nil) }
                if status.state == state { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Local server did not reach expected state: \(state)")
        }
        defer { server.stop() }
        server.start()
        try await waitFor(.waiting)
        XCTAssertNotNil(status.setupCode)
        let first = try XCTUnwrap(backing.load())
        let date = Date()
        server.update(sensorSnapshot(SensorReading(value: 22.5, receivedAt: date)), connected: true, now: date)
        try await waitFor(.awaitingPairing)
        server.update(DysonSnapshot(), connected: false, now: Date())
        try await waitFor(.waiting)
        server.stop()
        try await waitFor(.disabled)
        server.start()
        try await waitFor(.waiting)
        let again = try XCTUnwrap(backing.load())
        let a = try JSONSerialization.jsonObject(with: first) as! NSDictionary
        let b = try JSONSerialization.jsonObject(with: again) as! NSDictionary
        XCTAssertEqual(a["identifier"] as? String, b["identifier"] as? String)
        let recovered = Date()
        server.update(sensorSnapshot(SensorReading(value: 23, receivedAt: recovered)), connected: true, now: recovered)
        try await waitFor(.awaitingPairing)
        server.reset()
        try await waitFor(.disabled)
        XCTAssertNil(try backing.load())
    }
    func testPairedServerRecoversFromUnavailableAndExpiredReadingsWithoutRestart() async throws {
        let backing = MemoryHomeKitIdentity()
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        var saved = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! [String: Any]
        let controller = Data("synthetic-controller".utf8).base64EncodedString()
        saved["pairings"] = [controller, ["identifier": controller,
            "publicKey": Data(repeating: 7, count: 32).base64EncodedString(), "role": 1]] as [Any]
        try backing.save(JSONSerialization.data(withJSONObject: saved))
        let original = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        let discovery = FakeHomeKitBonjourMonitor()
        let server = DysonHomeKitServer(backing: backing, discovery: discovery)
        var status = DysonHomeKitStatus()
        var waits = 0
        server.onStatus = { status = $0; if $0.state == .waiting { waits += 1 } }
        defer { server.stop() }
        func waitFor(_ state: DysonHomeKitStatus.State) async throws {
            for _ in 0..<600 {
                if status.state == state { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Expected \(state), got \(status.state)")
        }
        server.start()
        try await waitFor(.waiting)
        let initial = Date()
        server.update(sensorSnapshot(SensorReading(value: 22, receivedAt: initial)), connected: true, now: initial)
        try await waitFor(.advertising)
        discovery.finish(error: nil)
        XCTAssertEqual(status.state, .paired)
        for cause in 0..<7 {
            let now = Date()
            let unavailable: SensorReading? = cause == 2
                ? SensorReading(value: 22, receivedAt: now.addingTimeInterval(-120))
                : (cause == 3 ? SensorReading(value: 101, receivedAt: now) : nil)
            let previousWaits = waits
            // Queue loss and recovery together: do not allow callbacks to release the old
            // server first, and do not mask recovery with a stop/start of the integration.
            var lost = cause < 4 ? sensorSnapshot(unavailable) : sensorSnapshot(SensorReading(value: 23, receivedAt: now))
            if cause == 4 { lost.humidity = nil }
            if cause == 5 { lost.pm25 = nil }
            if cause == 6 { lost.pm10 = nil }
            server.update(lost, connected: cause != 0, now: now)
            server.update(sensorSnapshot(SensorReading(value: 23, receivedAt: now)), connected: true, now: now)
            try await waitFor(.advertising)
            XCTAssertGreaterThan(waits, previousWaits)
            discovery.finish(error: nil)
            XCTAssertEqual(status.state, .paired)
        }
        // Expire while no new messages arrive, then restore a real fresh reading.
        let expiryStart = Date()
        server.update(sensorSnapshot(SensorReading(value: 23, receivedAt: expiryStart.addingTimeInterval(-118))), connected: true, now: expiryStart)
        try await waitFor(.waiting)
        let recovered = Date()
        server.update(sensorSnapshot(SensorReading(value: 24, receivedAt: recovered)), connected: true, now: recovered)
        try await waitFor(.advertising)
        discovery.finish(error: nil)
        XCTAssertEqual(status.state, .paired)
        let restored = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        for key in ["identifier", "privateKey", "setupCode", "setupKey", "pairings", "aidForAccessorySerialNumber"] {
            XCTAssertEqual(original[key] as? NSObject, restored[key] as? NSObject)
        }
    }

    func testLocalServerIsActuallyDiscoverableThroughBonjour() async throws {
        let backing = MemoryHomeKitIdentity()
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! [String: Any]
        let probe = HomeKitBonjourProbe(identifier: try XCTUnwrap(object["identifier"] as? String))
        let server = DysonHomeKitServer(backing: backing)
        defer { probe.stop(); server.stop() }
        probe.start(); server.start()
        let date = Date()
        server.update(sensorSnapshot(SensorReading(value: 22, receivedAt: date)), connected: true, now: date)
        for _ in 0..<600 {
            if probe.found { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(probe.found, "A listening socket alone does not prove Bonjour publication")
    }
    func testReadyRequiresSuccessfulBonjourDiscoveryAndFailureCanBeRetried() async throws {
        let backing = MemoryHomeKitIdentity()
        let discovery = FakeHomeKitBonjourMonitor()
        let server = DysonHomeKitServer(backing: backing, discovery: discovery)
        var status = DysonHomeKitStatus()
        server.onStatus = { status = $0 }
        defer { server.stop() }
        func waitFor(_ state: DysonHomeKitStatus.State) async throws {
            for _ in 0..<600 {
                if status.state == state { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Expected status: \(state)")
        }
        server.start()
        let date = Date()
        server.update(sensorSnapshot(SensorReading(value: 22, receivedAt: date)), connected: true, now: date)
        try await waitFor(.advertising)
        XCTAssertNotNil(status.setupURI)
        XCTAssertEqual(discovery.starts, 1)
        discovery.finish(error: "Local network discovery is unavailable.")
        XCTAssertEqual(status.state, .failed)
        server.update(sensorSnapshot(SensorReading(value: 22, receivedAt: date)), connected: true, now: Date())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(status.state, .failed, "Sensor updates must not mask a discovery error")
        XCTAssertEqual(discovery.starts, 1)
        server.stop()
        try await waitFor(.disabled)
        server.start()
        let retry = Date()
        server.update(sensorSnapshot(SensorReading(value: 22, receivedAt: retry)), connected: true, now: retry)
        try await waitFor(.advertising)
        XCTAssertEqual(discovery.starts, 2)
        discovery.finish(error: nil)
        XCTAssertEqual(status.state, .awaitingPairing)
        XCTAssertNil(status.error)
    }
    func testQRCodeDecodesToPersistedHAPSetupURI() throws {
        let backing = MemoryHomeKitIdentity()
        let (device, _) = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let uri = device.setupURI
        let image = try XCTUnwrap(HomeKitPairingQRCode.image(for: uri))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(features.first?.messageString, uri)
        let (restarted, _) = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        XCTAssertEqual(restarted.setupURI, uri)
        for invalid in ["", "https://example.com", "X-HM://invalid", "X-HM://000000000AB?D"] {
            XCTAssertNil(HomeKitPairingQRCode.image(for: invalid))
        }
    }
    func testControllerPairingSurvivesRestart() throws {
        let backing = MemoryHomeKitIdentity()
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        var object = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! [String: Any]
        let identifier = Data("synthetic-controller".utf8).base64EncodedString()
        object["pairings"] = [identifier, ["identifier": identifier,
                                         "publicKey": Data(repeating: 7, count: 32).base64EncodedString(), "role": 1]] as [Any]
        try backing.save(JSONSerialization.data(withJSONObject: object))
        let original = try backing.load()
        let (device, _) = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        XCTAssertTrue(device.isPaired)
        let before = try JSONSerialization.jsonObject(with: XCTUnwrap(original)) as! NSDictionary
        let after = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        XCTAssertEqual(before["pairings"] as? NSObject, after["pairings"] as? NSObject)
    }
    func testCorruptIdentityIsNeverOverwritten() throws {
        let backing = MemoryHomeKitIdentity()
        let corrupt = Data(#"{"identifier":"existing-identity"}"#.utf8)
        try backing.save(corrupt)
        XCTAssertThrowsError(try HomeKitIdentityStorage(backing: backing).prepareDevice())
        XCTAssertEqual(try backing.load(), corrupt)
        XCTAssertEqual(backing.saves, 1)
    }
    func testStorageFailuresDoNotSilentlyGenerateIdentity() throws {
        let backing = MemoryHomeKitIdentity()
        backing.failLoad = true
        XCTAssertThrowsError(try HomeKitIdentityStorage(backing: backing))
        XCTAssertEqual(backing.saves, 0)
        backing.failLoad = false; backing.failSave = true
        XCTAssertThrowsError(try HomeKitIdentityStorage(backing: backing).prepareDevice())
        XCTAssertNil(try backing.load())
    }
    func testArmedPairingStorageReportsWriteFailureWithoutReplacingStoredData() throws {
        let backing = MemoryHomeKitIdentity()
        let storage = try HomeKitIdentityStorage(backing: backing)
        _ = try storage.prepareDevice()
        let original = try backing.load()
        backing.failSave = true
        XCTAssertThrowsError(try storage.write(Data("uncommitted".utf8)))
        XCTAssertEqual(try backing.load(), original)
        XCTAssertEqual(try storage.read(), original)
    }
    func testStatusDeliveryAndDisabledStateDoNotExposeSetupCode() {
        let (store, _, server, _, _) = fixture()
        store.setDysonHomeKitEnabled(true)
        server.onStatus?(DysonHomeKitStatus(state: .awaitingPairing, setupCode: "248-36-579"))
        XCTAssertEqual(store.homeKitStatus.state, .awaitingPairing)
        server.onStatus?(DysonHomeKitStatus(state: .paired, isPaired: true))
        XCTAssertTrue(store.homeKitStatus.isPaired); XCTAssertNil(store.homeKitStatus.setupCode)
        store.setDysonHomeKitEnabled(false)
        server.onStatus?(DysonHomeKitStatus(state: .awaitingPairing, setupCode: "248-36-579"))
        XCTAssertEqual(store.homeKitStatus.state, .disabled); XCTAssertNil(store.homeKitStatus.setupCode)
    }
}

@MainActor private final class HomeKitControlRecorder {
    var commands: [DysonHomeCommand] = []
}

@MainActor final class HomeKitPurifierControlTests: XCTestCase {
    private func fixture(clock: any AppClock = SystemClock()) -> (HomeStore, FakeDyson, FakeDysonHomeKitServer) {
        let client = FakeDyson(), server = FakeDysonHomeKitServer(), config = MemoryConfiguration()
        config.saved.dyson = DysonConfiguration(host: "dyson.local", serial: "TEST", topicPrefix: "438", name: "Test")
        config.saved.dysonHomeKitEnabled = true
        let store = HomeStore(hue: FakeHue(), dyson: client, secrets: MemorySecrets(), persistence: config, clock: clock, homeKit: server)
        client.snapshot.hasState = true
        client.onSnapshot?(client.snapshot); client.onConnection?(.online, nil)
        return (store, client, server)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true")
    }
    func testCommandMappingAndInvalidSpeeds() throws {
        XCTAssertEqual(try DysonHomeCommand.power(true).fields(), ["fpwr": "ON"])
        XCTAssertEqual(try DysonHomeCommand.power(false).fields(), ["fpwr": "OFF"])
        XCTAssertEqual(try DysonHomeCommand.automatic(true).fields(), ["auto": "ON"])
        XCTAssertEqual(try DysonHomeCommand.automatic(false).fields(), ["auto": "OFF"])
        for (percent, speed) in [(10.0, 1), (50, 5), (100, 10), (1, 1), (24, 2), (25, 3)] {
            let command = try DysonHomeCommand.speed(percent: percent)
            XCTAssertEqual(command, .speed(speed))
            XCTAssertEqual(try command.fields(), ["fpwr": "ON", "auto": "OFF", "fnsp": String(format: "%04d", speed)])
        }
        XCTAssertEqual(try DysonHomeCommand.speed(percent: 0), .power(false))
        for invalid in [-1, 101, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try DysonHomeCommand.speed(percent: invalid))
        }
        XCTAssertThrowsError(try DysonHomeCommand.speed(11).fields())
        XCTAssertThrowsError(try DysonHomeCommand.speed(0).fields())
    }
    func testSharedCommandPathPreservesPowerAndModeSemantics() async throws {
        let (store, client, server) = fixture()
        defer { store.stop() }
        try await server.onControl?(.automatic(true))
        XCTAssertFalse(store.dyson.isOn); XCTAssertTrue(store.dyson.autoMode)
        try await server.onControl?(.power(true))
        XCTAssertTrue(store.dyson.isOn); XCTAssertTrue(store.dyson.autoMode)
        try await server.onControl?(.speed(5))
        XCTAssertTrue(store.dyson.isOn); XCTAssertFalse(store.dyson.autoMode); XCTAssertEqual(store.dyson.speed, 5)
        store.setDyson(["fpwr": "OFF"])
        try await waitUntil { !store.dysonPending }
        XCTAssertFalse(store.dyson.isOn); XCTAssertEqual(client.commands.count, 4)
    }
    func testOfflineAndTimeoutReturnErrors() async throws {
        let (store, client, server) = fixture(clock: FakeClock())
        defer { store.stop() }
        client.confirm = false
        do { try await server.onControl?(.power(false)); XCTFail("Missing timeout") }
        catch ControlError.timeout { }
        catch { XCTFail("Unexpected error: \(error)") }
        client.onConnection?(.offline, nil)
        do { try await server.onControl?(.power(true)); XCTFail("Missing offline error") } catch { }
        XCTAssertEqual(client.commands.count, 1)
    }
    func testQueueCoalescesAdjacentSpeedsAndPreservesModeBarrier() async throws {
        let (store, client, server) = fixture()
        defer { store.stop() }
        client.confirm = false
        let first = Task { try await server.onControl?(.power(true)) }
        try await waitUntil { client.commands.count == 1 }
        var tasks: [Task<Void?, Error>] = []
        for command in [DysonHomeCommand.speed(2), .speed(4), .automatic(true), .speed(7), .speed(8)] {
            tasks.append(Task { try await server.onControl?(command) })
            for _ in 0..<10 { await Task.yield() }
        }
        XCTAssertEqual(client.commands.count, 1, "No concurrent MQTT commands")
        client.confirm = true; client.snapshot.isOn = true; client.onSnapshot?(client.snapshot)
        _ = try await first.value
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(client.commands, [
            ["fpwr": "ON"], try DysonHomeCommand.speed(4).fields(),
            ["auto": "ON"], try DysonHomeCommand.speed(8).fields()])
    }
    func testDisconnectAndDisableCancelPendingCommandsWithoutOfflineDelivery() async throws {
        for disable in [false, true] {
            let (store, client, server) = fixture()
            client.confirm = false
            let active = Task { try await server.onControl?(.power(true)) }
            try await waitUntil { client.commands.count == 1 }
            let queued = Task { try await server.onControl?(.speed(8)) }
            for _ in 0..<10 { await Task.yield() }
            if disable { store.setDysonHomeKitEnabled(false) }
            else { client.onConnection?(.offline, nil) }
            do { _ = try await active.value; XCTFail("Active command must fail") } catch { }
            do { _ = try await queued.value; XCTFail("Queued command must fail") } catch { }
            client.onConnection?(.online, nil)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(client.commands.count, 1); XCTAssertFalse(store.dysonPending)
            store.stop()
        }
    }
    func testUpstreamWritesAreOptimisticAndReconciliationDoesNotLoop() throws {
        let recorder = HomeKitControlRecorder()
        let storage = try HomeKitIdentityStorage(backing: MemoryHomeKitIdentity())
        let (device, accessory) = try storage.prepareDevice { command in
            MainActor.assumeIsolated { recorder.commands.append(command) }
        }
        var actual = DysonSnapshot(); actual.hasState = true; actual.speed = 2
        accessory.reachable = true; accessory.applyControl(actual, connected: true)
        let services = accessory.serialized()["services"] as! [[String: Any]]
        func iid(service: String, characteristic: String) throws -> Int {
            let service = try XCTUnwrap(services.first { $0["type"] as? String == service })
            let chars = service["characteristics"] as! [[String: Any]]
            return try XCTUnwrap(chars.first { ($0["type"] as? String)?.uppercased() == characteristic }?["iid"] as? NSNumber).intValue
        }
        let power = try iid(service: "BB", characteristic: "B0")
        let speed = try iid(service: "BB", characteristic: "29")
        let mode = try iid(service: "BB", characteristic: "A8")
        let temperature = try iid(service: "8A", characteristic: "11")
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        func write(_ iid: Int, _ value: Int) throws -> HTTPResponse {
            let body = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": 1, "iid": iid, "value": value]]])
            return HAP.characteristics(device: device, channel: channel, request: HTTPRequest(method: .PUT, body: body))
        }
        // Upstream acknowledges before a Dyson snapshot and exposes the requested value.
        XCTAssertEqual(try write(speed, 50).status.code, 204)
        XCTAssertEqual(recorder.commands, [.speed(5)])
        XCTAssertEqual(accessory.purifier.rotationSpeed?.value, 50)
        actual.isOn = true; actual.speed = 5
        accessory.applyControl(actual, connected: true)
        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertEqual(try write(mode, 1).status.code, 204)
        XCTAssertEqual(recorder.commands.last, .automatic(true))
        actual.autoMode = true; actual.speed = nil
        accessory.applyControl(actual, connected: true)
        XCTAssertEqual(accessory.purifier.currentAirPurifierState.value, .purifyingAir)
        XCTAssertEqual(try write(power, 0).status.code, 204)
        XCTAssertEqual(accessory.purifier.active.value, .inactive)
        XCTAssertEqual(recorder.commands.last, .power(false))
        // A failed physical command is reconciled to actual state, not an HTTP error.
        accessory.applyControl(actual, connected: true)
        XCTAssertEqual(accessory.purifier.active.value, .active)
        XCTAssertEqual(recorder.commands.count, 3)
        accessory.reachable = false
        XCTAssertEqual(try write(power, 1).status.code, 400)
        XCTAssertEqual(recorder.commands.count, 3)
        let read = HAP.characteristics(device: device, channel: channel,
            request: HTTPRequest(method: .GET, uri: "/characteristics?id=1.\(temperature),1.\(power)"))
        XCTAssertEqual(read.status.code, 207)
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(read.body.data)) as! [String: Any]
        for result in json["characteristics"] as! [[String: Any]] {
            XCTAssertEqual(result["status"] as? Int, -70402); XCTAssertNil(result["value"])
        }
    }
    func testMissingOrExpiredSensorsPauseAllControlAndRecoverWithSamePairing() async throws {
        let discovery = FakeHomeKitBonjourMonitor(), backing = MemoryHomeKitIdentity()
        let server = DysonHomeKitServer(backing: backing, discovery: discovery)
        var status = DysonHomeKitStatus(); server.onStatus = { status = $0 }
        defer { server.stop() }
        server.start()
        var snapshot = DysonSnapshot(); snapshot.hasState = true; snapshot.isOn = true; snapshot.speed = 3
        server.update(snapshot, connected: true, now: Date())
        try await waitUntil { status.state == .waiting }
        XCTAssertFalse(status.controlAvailable); XCTAssertNil(status.readings)
        XCTAssertEqual(discovery.starts, 0)
        let initial = try XCTUnwrap(backing.load())
        let date = Date()
        func refreshSensors(_ date: Date) {
            snapshot.temperature = SensorReading(value: 20, receivedAt: date)
            snapshot.humidity = SensorReading(value: 40, receivedAt: date)
            snapshot.pm25 = SensorReading(value: 10, receivedAt: date)
            snapshot.pm10 = SensorReading(value: 20, receivedAt: date)
        }
        refreshSensors(date)
        server.update(snapshot, connected: true, now: date)
        try await waitUntil { status.state == .advertising }
        discovery.finish(error: nil)
        XCTAssertTrue(status.controlAvailable); XCTAssertNotNil(status.readings)
        server.update(snapshot, connected: true, now: date.addingTimeInterval(120))
        try await waitUntil { status.state == .waiting }
        XCTAssertFalse(status.controlAvailable); XCTAssertNil(status.readings)
        let recovered = date.addingTimeInterval(121)
        refreshSensors(recovered)
        server.update(snapshot, connected: true, now: recovered)
        try await waitUntil { status.state == .advertising }
        discovery.finish(error: nil)
        XCTAssertTrue(status.controlAvailable); XCTAssertNotNil(status.readings)
        let before = try JSONSerialization.jsonObject(with: initial) as! NSDictionary
        let after = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        for key in ["identifier", "privateKey", "setupCode", "setupKey", "pairings", "aidForAccessorySerialNumber", "number"] {
            XCTAssertEqual(before[key] as? NSObject, after[key] as? NSObject)
        }
    }
    func testUpstreamPreservesExistingPurifierPairingAndAllIIDs() throws {
        let backing = MemoryHomeKitIdentity(), storage = try HomeKitIdentityStorage(backing: MemoryHomeKitIdentity())
        let purifier = HAP.Service.AirPurifier(characteristics: [.rotationSpeed(minStep: 10)])
        // Simulate the previous local library's exposed primary flag using test-only access.
        purifier.primary = true
        let legacy = HAP.Accessory.Thermometer(info: HAP.Service.Info(name: "Dyson TP07", serialNumber: "homecontrol-temperature",
            manufacturer: "Home Control", model: "Dyson TP07"), additionalServices: [HAP.Service.HumiditySensor(),
                HAP.Service.AirQualitySensor(characteristics: [.pm25Density(unit: nil), .pm10Density(unit: nil)]), purifier])
        _ = HAP.Device(storage: storage, accessory: legacy)
        var saved = try JSONSerialization.jsonObject(with: storage.read()) as! [String: Any]
        let controller = Data("synthetic-controller".utf8).base64EncodedString()
        saved["pairings"] = [controller, ["identifier": controller,
            "publicKey": Data(repeating: 7, count: 32).base64EncodedString(), "role": 1]] as [Any]
        try backing.save(JSONSerialization.data(withJSONObject: saved))
        let (device, accessory) = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        XCTAssertTrue(device.isPaired)
        let after = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        for key in ["identifier", "privateKey", "setupCode", "setupKey", "pairings", "aidForAccessorySerialNumber", "number"] {
            XCTAssertEqual(saved[key] as? NSObject, after[key] as? NSObject)
        }
        var oldServices = legacy.serialized()["services"] as! [[String: Any]]
        oldServices[oldServices.count - 1].removeValue(forKey: "primary")
        XCTAssertEqual(oldServices as NSArray, accessory.serialized()["services"] as? NSArray)
        XCTAssertEqual(legacy.serialized()["aid"] as? NSNumber, accessory.serialized()["aid"] as? NSNumber)
    }
    func testExistingAirSensorPairingMigratesWithStableIdentifiers() throws {
        let backing = MemoryHomeKitIdentity(), storage = try HomeKitIdentityStorage(backing: MemoryHomeKitIdentity())
        let legacy = HAP.Accessory.Thermometer(info: HAP.Service.Info(name: "Dyson Temperature", serialNumber: "homecontrol-temperature",
            manufacturer: "Home Control", model: "Dyson Temperature"), additionalServices: [HAP.Service.HumiditySensor(),
                HAP.Service.AirQualitySensor(characteristics: [.pm25Density(unit: nil), .pm10Density(unit: nil)])])
        let oldDevice = HAP.Device(storage: storage, accessory: legacy)
        var saved = try JSONSerialization.jsonObject(with: storage.read()) as! [String: Any]
        let controller = Data("synthetic-controller".utf8).base64EncodedString()
        saved["pairings"] = [controller, ["identifier": controller,
            "publicKey": Data(repeating: 7, count: 32).base64EncodedString(), "role": 1]] as [Any]
        try backing.save(JSONSerialization.data(withJSONObject: saved))
        let (device, accessory) = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let migrated = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        for key in ["identifier", "privateKey", "setupCode", "setupKey", "pairings", "aidForAccessorySerialNumber"] {
            XCTAssertEqual(saved[key] as? NSObject, migrated[key] as? NSObject)
        }
        XCTAssertTrue(device.isPaired)
        XCTAssertEqual((migrated["number"] as? NSNumber)?.intValue, (saved["number"] as! NSNumber).intValue + 1)
        accessory.reachable = true
        let old = oldDevice.accessories[0].serialized(), new = accessory.serialized()
        XCTAssertEqual(old["aid"] as? NSNumber, new["aid"] as? NSNumber)
        let oldServices = old["services"] as! [NSDictionary], newServices = new["services"] as! [NSDictionary]
        let oldInfo = oldServices[0]["characteristics"] as! [NSDictionary]
        let newInfo = newServices[0]["characteristics"] as! [NSDictionary]
        XCTAssertEqual(oldInfo.map { $0["iid"] as? NSNumber }, newInfo.map { $0["iid"] as? NSNumber })
        XCTAssertEqual(Array(newServices.prefix(oldServices.count).dropFirst()), Array(oldServices.dropFirst()))
        XCTAssertEqual(accessory.info.name.value, "Dyson TP07")
        XCTAssertEqual(accessory.info.model.value, "Dyson TP07")
        XCTAssertEqual(newServices.count, oldServices.count + 1)
        _ = try HomeKitIdentityStorage(backing: backing).prepareDevice()
        let restarted = try JSONSerialization.jsonObject(with: XCTUnwrap(backing.load())) as! NSDictionary
        XCTAssertEqual(restarted["number"] as? NSNumber, migrated["number"] as? NSNumber)
    }
}
