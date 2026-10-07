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

Installation requires write access to `/Applications`. The script verifies the bundle's signature and refuses to replace an app with a different bundle identifier. The previous installation is retained until its replacement succeeds.

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

## Validation

```sh
xcodebuild -project HomeControl.xcodeproj -scheme HomeControl \
  -destination 'platform=macOS' -derivedDataPath build test
```

Tests cover message decoding, Kelvin conversion, pollutant fallbacks and sentinels, every air-quality boundary, partial updates and stale/offline readings; scene parsing, recall requests, selection persistence, bridge changes and stale command responses; brightness-on behavior and non-dimmable devices; state persistence and rollback, offline commands, confirmation/timeouts, Hue errors and connectivity, MyDyson login and rate limiting, credential decryption and firmware topic variants.

Debug builds also support `--preview-panel` with synthetic devices and in-memory settings (no Keychain or real-device traffic). Optional arguments: `--preview-theme=light|dark`, `--preview-quality=good|fair|poor|red`, `--preview-many`, and `--preview-empty`. Launch through the app bundle, for example:

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
