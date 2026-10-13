# Home Control

A Swift 6 menu bar app for macOS 27. Home Control manages one modern Hue Bridge and one Dyson TP07 over the local network.

## Requirements

- macOS 27 or later (the deployment target is 27.0).
- Xcode 27 or later with the macOS SDK and Swift 6 support.
- Internet access for the initial Swift package download and MyDyson setup.
- A compatible Hue Bridge and/or Dyson TP07 reachable over the local network.

## Build and run

To build an application bundle without installing or launching it:

```sh
./script/build_and_run.sh --app-build
```

The Release bundle is saved to `dist/HomeControl.app`. An already-running app remains running.

To build, install in `/Applications`, and launch the app:

```sh
./script/build_and_run.sh --app
```

The installed path is `/Applications/Home Control.app`. Installation requires write access to `/Applications`. The script advances the build number, refreshes LaunchServices registration, and retires the verified legacy `/Applications/HomeControl.app` bundle after successful replacement. The script verifies the bundle's signature and refuses to replace an app with a different bundle identifier. The previous installation is retained until its replacement succeeds.

By default, local builds use ad-hoc signing. Their signing identity changes with the binary, so macOS can ask for Keychain access again after an update, separately for the Hue, Dyson and HomeKit records. To keep the trusted application identity stable, set `HOME_CONTROL_SIGNING_IDENTITY` to an existing code-signing certificate's name or SHA-1 fingerprint when running the build script, and keep using the same certificate for subsequent builds. Switching from ad-hoc signing can still require approving each existing record once. The app keeps Keychain access restrictions intact.

### Development

Open `HomeControl.xcodeproj`, select the **HomeControl** scheme and run. Xcode resolves package dependencies automatically. Alternatively, use the build and launch script from the project directory:

```sh
./script/build_and_run.sh
```

The house icon appears in the menu bar without a Dock icon. Left-click opens the device panel. Right-click offers **Settings…** and **Quit**. **Connect** opens settings at the chosen integration. Debug builds support the `--show-settings` launch argument for inspection.

## Connect

**Hue:** discover a bridge or enter its IP/hostname, continue to verify its identity, press its physical link button, then choose **Connect**. The app retrieves lights, device types, rooms and scenes, and observes Hue's event stream. Lights and smart plugs appear in a two-column grid. Power switches act independently; clicking a dimmable light opens a brightness popover. Changing brightness also turns the light on. Devices without dimming never open a brightness popover.

Choose scenes in **Settings → Philips Hue → Scenes**. No scenes are selected automatically. Selected scenes appear as quick actions above the lights and are saved per bridge. Setting up the same bridge preserves the selection; selecting a different bridge resets it. Scenes are highlighted when their devices match the saved power, brightness and color settings, including smart plugs belonging to the scene. Powered-on appliances with the plug icon outside the scene do not affect matching; an additional powered-on lamp does. Hue's configured lamp icon identifies a plug used for lighting. Matching allows 3 percentage points of brightness, 0.01 distance in CIE xy color coordinates, and 5 mirek of color temperature. Clicking an active scene switches off only the devices that it sets to on; other lamps and plugs remain unchanged. Scene commands disable conflicting Hue controls until the bridge responds and the panel refreshes. Hue API v1 bridges are unsupported. Hue TLS is restricted to the bundled Hue root certificates and the selected bridge ID; redirects are refused. Older self-signed bridge certificates are rejected rather than accepted blindly.

**Dyson:** use **MyDyson**, supply the two-letter country code of your account, request an email verification code, then enter your password and code. Choose your device and its discovered hostname or enter its IP address. Only the TP07-compatible 438 family is handled; the firmware variant determines the MQTT topic prefix. If necessary, use **Manual** with the IP/hostname, serial, MQTT credential and actual topic prefix (`438`, `438E`, `438K`, `438M`). The MQTT credential is not the household Wi-Fi password. Mainland China accounts are not supported in this version.

MyDyson uses an unofficial application API and is used only during setup. Account passwords, verification codes and cloud tokens are not persisted. Local credentials are stored in Keychain; network addresses and identifiers are stored in `~/Library/Application Support/HomeControl/configuration.json`. Removing a connection deletes this app's saved data without switching devices off or removing lamps from the bridge.

Allow **Local Network** access when macOS asks. If access has been denied, enable Home Control in **System Settings → Privacy & Security → Local Network**. Both devices must be reachable from the Mac; VPNs and guest-network isolation can prevent discovery.

Temperature, humidity, PM2.5, PM10, VOC and NO₂ come directly from the TP07 over local MQTT. The purifier card shows temperature, humidity and the dominant fresh pollutant among PM2.5, PM10, VOC and NO₂. Pollutants are compared on the quality bands below, with linear interpolation within each band and a capped extension within the final band; exact ties use the listed order. PM readings use µg/m³; gas indices have no unit and retain one decimal place. If all readings are stale, the card retains the dominant last reading with its update time. Clicking the dominant pollutant opens a popover with PM2.5, PM10, VOC and NO₂. Each reading uses its own green/yellow/orange/red/pink/purple quality band, with a quality description for accessibility and the last update time for stale or offline data. Missing readings remain neutral. The air quality label's tooltip includes all four pollutants. Auto/Manual changes the mode without changing power. Adjusting fan speed switches to Manual and turns the purifier on.

The card's muted green/yellow/orange/red/pink/purple background reflects the worst fresh pollutant reading. PM2.5 boundaries are 36/54/71/151/251 µg/m³, PM10 boundaries are 51/76/101/351/421 µg/m³, and gas-index boundaries are 4/7/9 after dividing `va10` and `noxl` by ten. PM values prefer `p25r`/`p10r`, falling back to `pm25`/`pm10`. This is an app-calculated classification based on the local protocol, not a ready-made MyDyson score; exact MyDyson agreement needs hardware acceptance. Offline or missing/stale air-quality data produces a neutral background. Sensors are requested every 30 seconds. After two minutes without a valid temperature measurement, the menu bar temperature disappears; the panel retains the last reading with its update time. Continuous monitoring can be enabled explicitly in Dyson settings to receive readings while the fan is in standby. Device commands wait up to 10 seconds for confirmation and are never queued for later offline delivery.

## Apple Home sensor data (experimental)

In **Settings → Dyson TP07**, enable **Share data with Apple Home**. Sharing is disabled by default and publishes temperature, relative humidity, PM2.5, PM10 and overall air quality as a local HomeKit accessory named **Dyson Temperature**. It uses the embedded [Bouke/HAP](https://github.com/Bouke/HAP) library pinned to revision `51e3505a34eb842f7491fda48bb4ef873b16b68c`; there is no separate bridge process or external service.

Keep the Mac and iPhone/iPad on the same local network. Once all four numeric readings are fresh, open **Home → Add Accessory** and scan the QR code shown in settings. Alternatively, use **More Options**, choose **Dyson Temperature**, and enter its setup code. The QR is generated locally from HAP’s saved setup URI and does not transmit the code to an external service. The app shows **Checking visibility on the local network…** until its own accessory identity is discovered and resolved through Bonjour. A listening socket alone no longer produces **Ready to add to Apple Home**. If discovery fails, the app reports the Bonjour error code and domain; it does not infer that the Local Network permission switch is off. Choose **Check Visibility Again** to retry. The bundle declares canonical and fully qualified Bonjour service types, including `_hap._tcp.`. The installer uses a fresh application path and increasing build numbers because the legacy installation was observed rejecting `_hap._tcp` while an identical clean installation discovered it successfully. Check the Local Network permission only if access has actually been denied. Check VPN, firewall and Wi-Fi client isolation if the phone still cannot discover it. A QR code cannot bypass local network permissions. An uncertified-accessory notice may appear. Home Control must stay running and the Mac must stay awake; its panel does not need to be open. Enable Dyson's existing **Continuous monitoring** setting separately if readings are needed with the fan in standby.

All four numeric readings must be finite, less than 120 seconds old and not dated in the future. Temperature must be 0–100 °C, humidity 0–100%, and PM2.5/PM10 0–1000 µg/m³. If any required reading is missing, invalid or stale, or Dyson disconnects, the entire local accessory server pauses; Home may temporarily retain its own cached values before displaying unavailability. Publication resumes once all four readings are valid and fresh, using a new HAP object graph with the saved pairing. Overall air quality uses the same fresh-pollutant calculation as the app, including VOC and NO₂; those gas indices are not exported as concentrations. App levels Good/Fair/Poor/Very poor/Extremely poor/Severe map to HomeKit Excellent/Good/Fair/Inferior/Poor/Poor (1/2/3/4/5/5). Expiry of a gas reading recalculates quality even without new messages. This avoids HAP's default numeric value in accessory discovery responses. No extra Dyson polling is added.

Accessory identity, setup code, private keys and controller pairings are saved together in this app's Keychain under a separate account. Disabling sharing, restarting, network recovery and removal of the Dyson connection preserve the pairing. Removing Dyson disables sharing; reconnecting requires enabling it again. **Reset Apple Home Pairing…** explicitly disables sharing and deletes the saved identity. Remove the old accessory from Home before enabling sharing and adding it again. Storage errors stop publication and do not silently replace existing pairing keys.

Temperature, humidity, air quality, PM2.5 and PM10 have been verified in the macOS Home app with a real Dyson and an existing pairing. Sleep/wake, extended outages and explicit reset still need full hardware acceptance. Hardware acceptance: add the accessory and compare its temperature with the app, restart Home Control without re-adding it, disable/re-enable sharing, sleep/wake the Mac, disconnect/reconnect the network and Dyson, check unavailability after 120 seconds without a valid reading, and verify explicit reset requires a new pairing. The temperature-only accessory upgrades in place: existing temperature IIDs, accessory identity and controller pairings are preserved, with a single HAP configuration-number increment for the added services. The existing Home accessory displayed humidity, both particle densities and mapped air quality after updating without re-pairing. Purifier control, history and automatic launch are outside this experiment.

## Validation

```sh
xcodebuild -project HomeControl.xcodeproj -scheme HomeControl \
  -destination 'platform=macOS' -derivedDataPath build test
```

Tests cover message decoding, Kelvin conversion, pollutant fallbacks and sentinels, every air-quality boundary, partial updates and stale/offline readings; scene parsing, recall requests, selection persistence, bridge changes and stale command responses; brightness-on behavior and non-dimmable devices; state persistence and rollback, offline commands, confirmation/timeouts, Hue errors and connectivity, MyDyson login and rate limiting, credential decryption and firmware topic variants.

Debug builds also support `--preview-panel` with synthetic devices and in-memory settings (no Keychain or real-device traffic). Optional arguments: `--preview-theme=light|dark`, `--preview-quality=good|fair|poor|red`, `--preview-many`, and `--preview-empty`. Use `--preview-homekit=ready|waiting|paired|error` with `--show-settings` to inspect Apple Home states; preview uses an in-memory fake server and never accesses pairing keys or advertises synthetic sensors. Launch through the app bundle, for example:

```sh
open -n build/Build/Products/Debug/HomeControl.app --args --preview-panel --preview-theme=dark
```

Inspect both themes, all six quality backgrounds, long names/scrolling, a brightness popover, independent power toggles, scene activation and settings selection. Escape closes the brightness or pollutant popover before closing the main panel. Networking fixtures contain only dummy credentials.

Automated tests use simulated devices and network responses. Real Hue/TP07 integration, sleep/network recovery and local control without internet require hardware acceptance.

## Repository hygiene

The repository contains source code, tests, shared Xcode settings, the dependency lockfile and public Hue root certificates. `.gitignore` excludes build output, Xcode user settings, local editor/agent settings, environment files, credentials, signing keys, runtime configuration, logs and network captures. The bundled `HomeControl/Resources/HueRootCA.pem` is explicitly included because it contains public trust anchors required for Hue TLS validation.

Personal Hue keys and Dyson MQTT credentials belong in macOS Keychain. Runtime addresses and device identifiers belong in `~/Library/Application Support/HomeControl/configuration.json`, outside the repository. Do not copy account details, device manifests, Keychain exports or real network responses into source files, tests or documentation. Test credentials and certificate fixtures are synthetic; MyDyson's fixed protocol decryption key is not a personal account credential.

Before committing, review the proposed files and staged changes:

```sh
git add --dry-run .
git add .
git diff --cached --stat
git diff --cached
```

Ignore rules apply to untracked files; they do not remove files already committed or prevent secrets embedded in source code from being committed. Review sanitized environment templates before including them.

## Structure

- `App`: application lifecycle, menu bar and singleton settings window.
- `Views`: SwiftUI panel and connection/settings screens.
- `Stores`: observable state, onboarding and persistence.
- `Services`: Hue HTTPS/SSE, MyDyson HTTPS, Dyson MQTT, Bonjour and replaceable interfaces.
- `Models`: device/configuration/sensor value types.
- `Resources/Localizable.xcstrings`: English string catalog.

CocoaMQTT is pinned at **2.1.6**, with transitive revisions recorded in Xcode's `Package.resolved`. A standalone `Package.swift` is included for compiler/test tooling; GUI launches should use the Xcode-built app bundle.

## Protocol references

- [Hue pairing and discovery](https://developers.meethue.com/develop/get-started-2/)
- [Hue HTTPS guidance](https://developers.meethue.com/develop/application-design-guidance/using-https/)
- [Hue root certificates](https://github.com/openhue/openhue-go/blob/main/certs.go)
- [Dyson local integration and TP07 support](https://github.com/libdyson-wg/ha-dyson)
- [MyDyson protocol reference](https://github.com/libdyson-wg/libdyson-neon/tree/main/libdyson/cloud)
- [CocoaMQTT](https://github.com/emqx/CocoaMQTT)

No cloud control, schedules, light colors/scenes, historical measurements, login item or distribution/notarization setup is included.

For isolated Bonjour troubleshooting, launch the GUI bundle with `open -n "/Applications/Home Control.app" --args --diagnose-bonjour`. This eight-second diagnostic compares Foundation and Network discovery without reading configuration or Keychain. It logs only service types, counts and errors under the `BonjourDiagnostic` category; it never reads or prints pairing codes.
