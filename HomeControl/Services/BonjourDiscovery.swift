import Foundation
import Network
import Observation

@MainActor @Observable final class BonjourDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var error: String?
    private(set) var isSearching = false
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var timeout: Task<Void, Never>?
    func start(kind: DeviceKind) {
        stop(); devices = []; error = nil; isSearching = true
        browser.delegate = self
        browser.searchForServices(ofType: kind == .hue ? "_hue._tcp." : "_dyson_mqtt._tcp.", inDomain: "local.")
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
    func stop() {
        browser.stop(); services.forEach { $0.stop() }; services = []; timeout?.cancel(); timeout = nil; isSearching = false
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        error = ControlError.localNetworkDenied.localizedDescription; stop()
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let bridge = txt["bridgeid"].flatMap { String(data: $0, encoding: .utf8) }
        let serial = txt["serial"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        let device = DiscoveredDevice(id: bridge ?? serial, name: sender.name, host: host.trimmingCharacters(in: CharacterSet(charactersIn: ".")), bridgeID: bridge)
        if !devices.contains(where: { $0.id == device.id }) { devices.append(device) }
    }
}
