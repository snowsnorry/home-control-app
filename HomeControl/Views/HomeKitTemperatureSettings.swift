import SwiftUI
import CoreImage.CIFilterBuiltins

struct HomeKitTemperatureSettings: View {
    let store: HomeStore
    @State private var confirmsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Apple Home · Experimental").font(.headline)
            Toggle("Share data with Apple Home", isOn: Binding(
                get: { store.configuration.homeKitTemperatureEnabled == true },
                set: { store.setHomeKitTemperatureEnabled($0) }))
                .disabled(store.configuration.dyson == nil)
            Text(LocalizedStringKey(store.homeKitStatus.state.rawValue)).foregroundStyle(.secondary)
            if store.homeKitStatus.isPaired {
                Label("Pairing is saved", systemImage: "checkmark.shield")
            }
            if store.configuration.homeKitTemperatureEnabled == true,
               let code = store.homeKitStatus.setupCode {
                LabeledContent("Setup code", value: code).textSelection(.enabled)
                if store.homeKitStatus.state == .awaitingPairing,
                   let uri = store.homeKitStatus.setupURI,
                   let image = HomeKitPairingQRCode.image(for: uri) {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.none).frame(width: 192, height: 192)
                        .background(.white).accessibilityHidden(true)
                    Text("In Home on your iPhone or iPad, tap Add Accessory and scan this QR code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("On your iPhone or iPad, open Home → Add Accessory → More Options, select Dyson Temperature, and enter this code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Your Mac and iPhone must be on the same local network. Sharing requires Home Control to be running and your Mac to be awake. The accessory requires fresh temperature, humidity, PM2.5 and PM10 readings. If any reading is unavailable or 120 seconds old, all shared readings become unavailable until fresh data returns.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Apple Home compatibility has not yet been verified with physical devices.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.homeKitStatus.error { ErrorNotice(message: String(localized: String.LocalizationValue(error))) }
            if store.configuration.homeKitTemperatureEnabled == true {
                Button("Check Visibility Again") { store.restartHomeKitAfterNetworkChange() }
            }
            Button("Reset Apple Home Pairing…", role: .destructive) { confirmsReset = true }
        }
        .confirmationDialog("Reset Apple Home pairing?", isPresented: $confirmsReset) {
            Button("Reset Pairing", role: .destructive) { store.resetHomeKitPairing() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This disables sharing and removes the saved pairing. Remove the old Dyson Temperature accessory from Home, then enable sharing and add it again.")
        }
    }
}

/// Generate locally from HAP's persisted setup URI, preserving its setup hash and pairing code.
enum HomeKitPairingQRCode {
    static func image(for uri: String) -> CGImage? {
        guard uri.hasPrefix("X-HM://"), uri.count == 20,
              uri.dropFirst(7).allSatisfy({ $0.isASCII && ($0.isNumber || ($0 >= "A" && $0 <= "Z")) }),
              let message = uri.data(using: .ascii) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = message; filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Four white modules on every edge are required for reliable scanning.
        let bounds = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: .white).cropped(to: bounds)
        let padded = output.composited(over: white).cropped(to: bounds)
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
