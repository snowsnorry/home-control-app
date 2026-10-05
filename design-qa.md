# Home Control UI verification

final result: blocked

## Reference and implemented behavior

The attached Home Control mockup is the visual reference. The implementation uses a 480 pt native NSPopover with a fixed header, selected Hue scenes, a two-column light/plug grid, separate brightness popovers, and a purifier card with a transparent TP07 product image and adaptive air-quality backgrounds.

The existing native AppKit menu bar/popover lifecycle remains in place. Brightness and power controls are separate sibling controls. PanelPresentation routes Escape to brightness before the main panel. Device controls expose accessible names, state values and standard native sliders/toggles. Device images and decorative icons are hidden from accessibility.

## Completed validation

- Xcode Debug app build succeeds with the new SwiftUI components, image resource and localization catalog.
- The XCTest suite was executed headlessly through SwiftPM using the same project sources and Xcode's already-resolved CocoaMQTT/MqttCocoaAsyncSocket source checkouts. A temporary all-local package harness avoided network dependency resolution; no production manifests/dependency versions were changed for this harness.
- All 46 tests pass. Coverage includes pollutant parsing/fallbacks/sentinels, all air-quality boundaries, stale/offline neutrality, Hue scene recall wire format/errors, saved selections and bridge changes, obsolete command responses, brightness-on behavior, plug rejection, Escape selection state and availability of every mapped SF Symbol.
- Xcode's hosted test execution was interrupted after the host did not begin executing tests. This run is not claimed as passed.
- The TP07 asset has an RGBA alpha channel and is included in both app and SwiftPM resources.
- Source diff whitespace checks pass.

## Earlier blocking condition

The native computer-use tool reported: “The Mac is locked and automatic unlock could not unlock it.” The user was asked to unlock the Mac while implementation and headless validation continued.

Native capture became available during the card-density refinement. The current populated panel was inspected, and the user supplied a matching dark-appearance screenshot. The broader acceptance matrix below, including both appearances, nested popovers and keyboard/VoiceOver operation, is still incomplete.

## Pending visual acceptance

Use the Debug app's --preview-panel mode with in-memory synthetic fixtures (no real device commands or Keychain access).

- Compare light/dark screenshots to the mockup at the same panel width, including an open brightness popover.
- Inspect good/fair/poor/red backgrounds in both themes; text and controls must remain legible.
- Exercise power switches independently of card click, mouse/keyboard brightness, scene activation, settings selection, and two-step Escape dismissal.
- Inspect --preview-many and --preview-empty for long names, scroll behavior and connection placeholders; inspect offline/unreachable/stale readings with disconnected devices or additional fixtures.
- Confirm the outer popover remains open while interacting with the brightness popover; selected-card borders clear on dismissal.
- Confirm keyboard focus and VoiceOver names/values for all controls.

## Hardware acceptance

Real Hue scene recall, TP07 sensor field availability, sleep/network recovery and exact comparison with MyDyson's air-quality classification require physical-device acceptance. The displayed air-quality level is calculated from device sensor readings rather than a reported MyDyson overall score.

## Brightness popover refinement

The user's attached screenshot (`codex-clipboard-f73c0b81-f2fa-4c5d-972e-11a5f0056f87.png`) shows a repeated lamp title/icon, a second inline Brightness label touching the slider, and a dense tick-mark row below the track.

The scoped correction removes the lamp header, divider and decorative sun icons. The normal state now has only a Brightness/percentage row and a full-width continuous slider below it: 260 pt overall width, 18 pt padding and 12 pt vertical separation. The native control label is visually hidden but its lamp-specific accessible name remains. Continuous drag values are rounded when submitting, preserving whole-percent commands without generating native tick marks. The pending indicator sits in the caption row, so waiting does not add another row or change popover height. Error details remain available when a command fails.

Validation: Xcode Debug build and app restart/process verification succeeded; source whitespace checks pass. Native visual verification was attempted twice. The first attempt timed out; the second reported that the Mac is locked and cannot be unlocked automatically. This correction is implemented but its rendered appearance and interaction have not yet been visually verified. The overall visual result remains blocked.

## Card density and purifier slider refinement

The user's full-panel screenshot (`codex-clipboard-d7b54f71-18c6-44b7-b511-2ae6da615b53.png`) shows excessive space below light status and a repeated Fan speed label consuming the slider track. The user clarified that tick marks may remain if readable, or the slider design may be revised.

Light cards now reserve the power switch's space in the status row, with the actual switch remaining a sibling of the brightness button. The extra bottom padding is removed and the minimum card height is reduced from 92 pt to 68 pt. Two-line names can still increase the card height; pending indicators also have reserved space.

The purifier shows one compact Fan speed label, 12 pt separation from the native slider, and a trailing Auto/integer value. The hidden native label retains its accessible name. The slider retains integer steps for mouse, keyboard and accessibility adjustments. Native macOS still displays the spaced automatic marks with a nil custom-tick closure; these marks were retained under the user's clarification allowing readable divisions. Draft values display as whole speeds and commands are submitted when dragging ends. Existing power/Manual behavior is preserved.

Validation: Xcode Debug build and app restart/process verification succeeded; all 46 existing tests pass in the local headless harness and source whitespace checks pass. Two native visual-verification attempts returned computer-use timeouts, so the rendered layout and interaction remain unverified.

## Panel height refinement and current screenshot assessment

After the smaller cards exposed unused space at the bottom of the fixed-height popover, DevicePanel now measures its header and scroll content and reports their combined height to the existing NSPopover. Height is capped at 700 pt or the available screen height. The scroll viewport expands only to the needed height, preserving the fixed header and 20 pt content padding. Changes to scenes, devices, wrapped names and notices update the measured height.

Validation: Xcode Debug build and restart/process verification succeeded; all 46 tests pass in the local headless harness; source whitespace checks pass. Native computer-use access recovered and a populated panel screenshot was captured. The user's dark screenshot (`codex-clipboard-b8f3f3a0-a3d7-46b3-9a30-0007362ba378.png`) confirms the large empty bottom area is gone, switches align with state text, and the single Fan speed label has space before the slider. Step divisions are spaced and readable. The user confirmed that the first smart plug is configured for a lamp and the second for a device; their different icons are correct.

The scoped populated-panel layout is visually verified. Many-device scrolling, empty states, both themes and interactive keyboard/VoiceOver checks remain in the broader acceptance matrix.


## Hue scene palette refinement

Scoped result: passed. Scene styling now comes from bridge data rather than the button's position in the grid. The first valid palette color tints the card, and a landscape gradient thumbnail shows the ordered palette. Hue has no separate dominant-color marker. CIE xy colors are converted to normalized display RGB; mirek entries receive a warm/cool white approximation. Display normalization keeps dim scenes recognizable. When a scene has no usable palette, its saved per-light action colors are used, excluding off/zero-brightness actions and exact duplicates. A scene without any colors uses a neutral treatment.

Titles retain two lines with full-width text and a room caption. Active scenes have an adaptive outline and a checkmark on the thumbnail; pending recall uses the same badge space and an accessible waiting value. No additional bridge requests or external image downloads are introduced.

Validation: all 52 XCTest tests pass in the existing temporary local SwiftPM harness, including six new tests for palette order/precedence, white/mixed palettes, static-action fallback, malformed entries, normalized xy conversion, and temperature/range validation. Xcode Debug build succeeds. Native captures show the scene cards in dark and light appearances. The extended `--preview-scene-palettes` fixture covers white, warm white, absent colors and a long name. Test-only scene activation updates both the active outline/checkmark and accessibility value; white-palette selection remains visible in light appearance. Debug preview appearance now explicitly applies to the NSPopover, so the menu bar's appearance cannot override the requested test theme. Broader hardware and VoiceOver acceptance above remains separate.


## User-controlled panel height

Scoped result: passed. The native NSPopover keeps its 480 pt width. Its initial/minimum height remains the previous content-fitting height capped at 700 pt (or the available display height). If more vertical space can reveal more content, a 12 pt footer supplies a subtle bottom resize grip. Mouse tracking uses screen coordinates while changing NSPopover.contentSize without size animation, so the top/menu-bar anchor remains stable during a drag. Height is limited to the measured full content plus footer, and to the current display's visible height minus 40 pt for popover chrome/margins. Content-fitting panels have no grip or extra footer.

The selected height lives in PanelPresentation across popover openings for this app session. It is clamped when content or display bounds change, preventing empty space. Double-clicking the grip expands to the maximum. The focused grip supports Up/Down in 20 pt steps and Home/End; a synthetic native Slider accessibility representation exposes the same height with Increment/Decrement actions. New labels/help are in the English string catalog.

Validation: Xcode Debug build and all 56 XCTest tests pass in the existing local harness. Four new sizing tests cover the unchanged default/minimum, full-content maximum, smaller content, display caps and retained preference after brightness dismissal. Native dark-theme dragging changed height from 700 to 780 pt; double-click expanded the extended palette fixture to 809 pt and removed the scroll bar, showing the complete purifier card. An upward drag clamped at 700 pt; Down increased it to 720 pt. Light-theme accessibility Increment also increased 700 to 720 pt, and double-click expanded to the same complete 809 pt layout. Opening brightness after resizing and pressing Escape closed brightness while keeping the main panel at 809 pt. Observation after the second Escape timed out, so that closure is not asserted from capture. A many-device fixture expanded to the display cap of 1370 pt, retained scrolling, and successfully scrolled to its end. A shorter standard fixture showed all content with no height control or scroll bar. No physical-device commands were used in these checks.


## Compact scene cards

Scoped final result: blocked (native visual capture unavailable).

The user's scene screenshot and requested changes define this scoped update: replace the landscape palette strip with a 24 pt circle beside the title, allow the title to wrap without truncation, and move the room caption directly below it with 2 pt spacing. The existing palette order, card tint, outline, active checkmark, pending indicator and scene activation remain in the same component. Single-line cards use a 32 pt text area plus 20 pt total vertical padding rather than reserving a two-line title below a separate palette strip.

Validation: Xcode Debug build succeeded and source whitespace checks passed. The extended synthetic scene preview was launched in light appearance. Three native capture attempts returned timeoutReached, so rendered wrapping, light/dark appearance and activation visuals are unverified for this update. No physical-device commands were issued.


## Equal scene card heights

Scoped final result: blocked (native visual capture unavailable).

The user's follow-up screenshot confirms the compact circle/title layout and shows unequal card heights when a title wraps. A custom three-column SwiftUI Layout now measures every scene at the actual column width and proposes the largest natural card height to all cells, including subsequent rows. Card backgrounds fill that height, with content aligned to the top. The layout recomputes from the current titles and available width without retaining a stale maximum.

Validation: Xcode Debug build succeeded and source whitespace checks passed. Native inspection returned timeoutReached, so the rendered equal-height layout remains unverified.
