import AppKit
import SwiftUI
import Observation
import Network
import OSLog

/// A path notification is not a connection failure. Only recovery from an
/// unavailable path should accelerate the clients' existing retry loops.
struct NetworkRecoveryPolicy {
    private var wasAvailable: Bool?

    mutating func shouldRecover(isAvailable: Bool) -> Bool {
        defer { wasAvailable = isAvailable }
        return isAvailable && wasAvailable == false
    }
}

@main enum HomeControlApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--diagnose-bonjour") {
            let diagnostic = BonjourDiagnostic()
            application.setActivationPolicy(.accessory)
            diagnostic.start()
            withExtendedLifetime(diagnostic) { application.run() }
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private let store: HomeStore
    override init() {
        #if DEBUG
        store = CommandLine.arguments.contains("--preview-panel") ? PanelPreview.makeStore(arguments: CommandLine.arguments) : HomeStore()
        #else
        store = HomeStore()
        #endif
        super.init()
    }
    private let wizard = ConnectionWizard()
    private let presentation = PanelPresentation()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var networkRecovery = NetworkRecoveryPolicy()
    private var badgeTask: Task<Void, Never>?
    private var lastBadge: String?
    private var escapeMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let theme = CommandLine.arguments.first(where: { $0.hasPrefix("--preview-theme=") }), CommandLine.arguments.contains("--preview-panel") {
            let appearance = NSAppearance(named: theme.hasSuffix("dark") ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            // A status-item popover can inherit the menu bar's appearance instead of the app's.
            popover.appearance = appearance
        }
        #endif
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: String(localized: "Home Control"))
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = String(localized: "Home Control")
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 480, height: 464)
        popover.contentViewController = NSHostingController(rootView: makeDevicePanel())
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.reconnect(.hue); self?.store.reconnect(.dyson); self?.store.restartHomeKitAfterNetworkChange() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.networkRecovery.shouldRecover(isAvailable: isAvailable) else { return }
                self.store.recoverConnectionsAfterNetworkChange()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "homecontrol.network"))
        store.start()
        badgeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateBadge()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popover.isShown == true {
                if self?.presentation.closeDetailPopover() != true { self?.popover.performClose(nil) }
                return nil
            }
            return event
        }
        installApplicationMenu()
        #if DEBUG
        if CommandLine.arguments.contains("--preview-panel") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                if let button = self.statusItem?.button { self.statusClicked(button) }
            }
        }
        if CommandLine.arguments.contains("--show-settings") { showSettings(nil) }
        #endif
    }
    private func installApplicationMenu() {
        let main = NSMenu(); let app = NSMenu(); let item = NSMenuItem(); item.submenu = app; main.addItem(item)
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ","); settings.target = self
        app.addItem(settings); app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit Home Control"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: String(localized: String.LocalizationValue(title)), action: Selector(action), keyEquivalent: key)
        }
        main.addItem(editItem); NSApp.mainMenu = main
    }
    private func updateBadge() {
        let badge = store.badge
        guard badge != lastBadge else { return }; lastBadge = badge
        statusItem?.button?.title = badge.map { " " + $0 } ?? ""
        statusItem?.button?.setAccessibilityLabel(String(localized: "Home Control") + (badge.map { ", " + $0 } ?? ""))
    }
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ","); settings.target = self
            menu.addItem(settings); menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else if popover.isShown { popover.performClose(nil) }
        else {
            let height = max(1, (sender.window?.screen?.visibleFrame.height ?? 740) - 40)
            popover.contentSize = NSSize(width: 480, height: min(popover.contentSize.height, height))
            if let controller = popover.contentViewController as? NSHostingController<DevicePanel> {
                controller.rootView = makeDevicePanel(maximumHeight: height)
            }
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    private func makeDevicePanel(maximumHeight: CGFloat = 700) -> DevicePanel {
        DevicePanel(store: store, presentation: presentation, maximumHeight: maximumHeight, heightChanged: { [weak self] height in
            guard let self, abs(self.popover.contentSize.height - height) > 0.5 else { return }
            let animates = self.popover.animates
            self.popover.animates = false
            self.popover.contentSize = NSSize(width: 480, height: height)
            self.popover.animates = animates
        }, openSettings: { [weak self] in self?.showSettings($0) })
    }
    func popoverDidClose(_ notification: Notification) {
        presentation.selectedLight = nil
        presentation.showsPollutants = false
    }
    @objc private func openSettings() { showSettings(nil) }
    private func showSettings(_ kind: DeviceKind?) {
        popover.performClose(nil)
        if let kind { wizard.begin(kind) }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 540), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = String(localized: "Home Control Settings")
            window.contentView = NSHostingView(rootView: SettingsView(store: store, wizard: wizard))
            window.isReleasedWhenClosed = false; window.delegate = self
            window.center(); settingsWindow = window
        }
        NSApp.activate(); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { wizard.cancel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        store.stop(); wizard.cancel(); pathMonitor.cancel(); badgeTask?.cancel()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}

/// Runs in the GUI bundle without opening settings, configuration or Keychain.
@MainActor private final class BonjourDiagnostic: NSObject, @preconcurrency NetServiceBrowserDelegate {
    private let log = Logger(subsystem: "com.homecontrol.mac", category: "BonjourDiagnostic")
    private var browsers: [NetServiceBrowser] = []
    private var types: [ObjectIdentifier: String] = [:]
    private var networkBrowser: NWBrowser?
    func start() {
        let bundleID = Bundle.main.bundleIdentifier ?? "missing"
        let declared = (Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []).joined(separator: ",")
        log.notice("Bundle=\(bundleID, privacy: .public); declared=\(declared, privacy: .public)")
        for type in ["_hap._tcp.", "_hue._tcp."] {
            let browser = NetServiceBrowser()
            browsers.append(browser); types[ObjectIdentifier(browser)] = type
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        let nw = NWBrowser(for: .bonjour(type: "_hap._tcp", domain: "local."), using: .tcp)
        networkBrowser = nw
        nw.stateUpdateHandler = { [log] state in
            log.notice("NWBrowser state: \(String(describing: state), privacy: .public)")
        }
        nw.browseResultsChangedHandler = { [log] results, _ in
            log.notice("NWBrowser result count: \(results.count, privacy: .public)")
        }
        nw.start(queue: DispatchQueue(label: "homecontrol.bonjour-diagnostic"))
        Task {
            try? await Task.sleep(for: .seconds(8))
            browsers.forEach { $0.stop() }
            networkBrowser?.cancel()
            NSApplication.shared.terminate(nil)
        }
    }
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        log.notice("NetService searching: \(self.types[ObjectIdentifier(browser)] ?? "unknown", privacy: .public)")
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log.error("NetService failed: \(self.types[ObjectIdentifier(browser)] ?? "unknown", privacy: .public); \(String(describing: errorDict), privacy: .public)")
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        log.notice("NetService found type: \(service.type, privacy: .public)")
    }
}
