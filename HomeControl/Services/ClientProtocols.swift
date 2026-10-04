import Foundation

@MainActor protocol HueClientProtocol: AnyObject {
    func identify(host: String, bridgeID: String?) async throws -> HueConfiguration
    func pair(configuration: HueConfiguration) async throws -> String
    func fetchSnapshot(configuration: HueConfiguration, key: String) async throws -> HueBridgeSnapshot
    func recallScene(configuration: HueConfiguration, key: String, id: String) async throws
    func setLight(configuration: HueConfiguration, key: String, id: String, on: Bool?, brightness: Double?) async throws
    func watch(configuration: HueConfiguration, key: String, changed: @escaping @MainActor () async -> Void) async throws
}
@MainActor protocol DysonClientProtocol: AnyObject {
    var onSnapshot: (@MainActor (DysonSnapshot) -> Void)? { get set }
    var onConnection: (@MainActor (ConnectionState, String?) -> Void)? { get set }
    func connect(configuration: DysonConfiguration, credential: String) async throws
    func disconnect()
    func requestSensors()
    func command(_ fields: [String: String]) throws
}
@MainActor protocol CloudDysonClientProtocol: AnyObject {
    func requestCode(email: String, country: String) async throws
    func verify(code: String, password: String) async throws -> [CloudDysonDevice]
    func reset()
}
@MainActor protocol SecretStoreProtocol {
    func read(_ account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
}
@MainActor protocol ConfigurationStoreProtocol {
    func load() throws -> SavedConfiguration
    func save(_ configuration: SavedConfiguration) throws
}
@MainActor protocol AppClock { var now: Date { get }; func sleep(seconds: Double) async throws }
struct SystemClock: AppClock {
    var now: Date { Date() }
    func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Cancellation propagates to URLSession when a slow request exceeds the command budget.
@MainActor func withCommandDeadline<T: Sendable>(seconds: Double = 10, operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ControlError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
