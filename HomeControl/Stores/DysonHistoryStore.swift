import Foundation
import Observation

@MainActor @Observable final class DysonHistoryStore {
    private(set) var isBusy = false
    private(set) var data: DysonHistory?
    private(set) var error: String?
    private(set) var updatedAt: Date?
    private(set) var needsAccountConnection = false

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var serial: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rejectedToken: String?
    @ObservationIgnored private let client: any DysonHistoryClientProtocol
    @ObservationIgnored private let sessions: MyDysonSessions
    @ObservationIgnored private let clock: any AppClock

    init(client: any DysonHistoryClientProtocol, secrets: any SecretStoreProtocol, clock: any AppClock) {
        self.client = client
        self.sessions = MyDysonSessions(secrets: secrets)
        self.clock = clock
    }

    func selectDevice(_ serial: String?) throws {
        guard serial != self.serial else { return }
        let previous = self.serial
        stop()
        token = nil
        rejectedToken = nil
        data = nil
        updatedAt = nil
        error = nil
        needsAccountConnection = false
        self.serial = serial
        if let previous { try sessions.remove(for: previous) }
    }

    func open() { load(force: false) }
    func refresh() { load(force: true) }

    func refreshAndWait() async throws {
        let selectedSerial = serial
        if let inFlight = task {
            await inFlight.value
            try Task.checkCancellation()
            guard !inFlight.isCancelled, serial == selectedSerial else { throw CancellationError() }
        }
        // A previous request may have used a token replaced by a newer login.
        // Re-read the shared session before starting the explicit retry.
        refresh()
        let request = task
        await request?.value
        try Task.checkCancellation()
        if request?.isCancelled == true || serial != selectedSerial { throw CancellationError() }
    }

    func stop() {
        task?.cancel()
        task = nil
        isBusy = false
        client.reset()
    }

    private func load(force: Bool) {
        guard let serial, !isBusy else { return }
        needsAccountConnection = false
        do {
            // Re-read on every open so a session saved by setup or diagnostics is
            // picked up even if this popover was opened before that login.
            let saved = try sessions.read(for: serial)
            if saved != token {
                token = saved
                data = nil
                updatedAt = nil
                rejectedToken = nil
            }
            guard let token else {
                needsAccountConnection = true
                error = String(localized: "No saved MyDyson account session is available. Choose Reconnect in Settings → Dyson TP07 to restore it.")
                return
            }
            guard token != rejectedToken else {
                needsAccountConnection = true
                error = DysonHistoryHTTPError(status: 401).localizedDescription
                return
            }
            guard force || (updatedAt.map({ clock.now.timeIntervalSince($0) >= 300 }) ?? true) else { return }
            isBusy = true
            error = nil
            task = Task {
                defer {
                    if !Task.isCancelled {
                        isBusy = false
                        task = nil
                    }
                }
                do {
                    let history = try await client.fetchHistory(serial: serial, token: token)
                    try Task.checkCancellation()
                    data = history
                    updatedAt = clock.now
                } catch {
                    guard !Task.isCancelled else { return }
                    if let failure = error as? DysonHistoryHTTPError, failure.status == 401 {
                        // Keep already loaded readings visible, but stop reusing
                        // the rejected session. Never start another login here.
                        // Do not delete shared Keychain state: another process may
                        // have saved a newer login while this request was running.
                        rejectedToken = token
                        needsAccountConnection = true
                    }
                    self.error = error is DecodingError
                        ? String(localized: "MyDyson returned history in an unexpected format.")
                        : error.localizedDescription
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
