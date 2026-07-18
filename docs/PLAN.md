# PLAN.md — EdgeGuard Implementation Plan

**Based on:** `EdgeGuardUITests/SPEC.md` and `CLAUDE.md`
**Target:** macOS 13.0+, Swift 6.0, SwiftUI + AppKit
**Date:** 2026-04-05

---

## Overview

EdgeGuard is a menu bar utility that wraps macOS Universal Control system preferences behind a friendly UI. The implementation strategy is bottom-up: system integration layer first, then menu bar UI, then ancillary features (hotkeys, login item). Each phase is independently buildable and testable.

The app requires **sandbox disabled** (or a targeted entitlement) because it must shell out to `defaults` and `pkill` to modify `com.apple.universalcontrol` domain preferences. This makes it a developer/power-user direct-download tool, not App Store-bound.

---

## Target File Structure

```
EdgeGuard/
├── EdgeGuardApp.swift            ← Existing (rewrite: wire AppDelegate, remove WindowGroup)
├── AppDelegate.swift             ← NEW: NSApplicationDelegate, NSStatusItem setup
├── MenuBarController.swift       ← NEW: Builds/updates NSMenu and icon state
├── UniversalControlService.swift ← NEW: Shell integration (defaults + pkill)
├── AppSettings.swift             ← NEW: UserDefaults-backed app preferences
├── GlobalHotkeyManager.swift     ← NEW: NSEvent global hotkey registration
└── ContentView.swift             ← Existing (delete or repurpose as empty; no window needed)
```

---

## Phase 0: Project Configuration

### 0.1 — Info.plist

Add the following keys so the app hides from the Dock and can explain its Accessibility use:

```xml
<key>LSUIElement</key>
<true/>

<key>NSAccessibilityUsageDescription</key>
<string>EdgeGuard uses Accessibility to register a global keyboard shortcut (⌘⌥⌃X) for quickly toggling Universal Control.</string>
```

### 0.2 — Entitlements / Sandbox

Remove the App Sandbox capability entirely from Signing & Capabilities. This allows:
- Unrestricted `Process()` execution of `/usr/bin/defaults` and `/usr/bin/pkill`
- Reading/writing `com.apple.universalcontrol` domain preferences

> **If App Store distribution is ever needed later**, replace "disable sandbox" with:
> ```xml
> <key>com.apple.security.temporary-exception.shared-preference.read-write</key>
> <array>
>   <string>com.apple.universalcontrol</string>
> </array>
> ```
> Note: this entitlement alone does not authorize `pkill`; a helper tool would be needed.

### 0.3 — Deployment Target

Confirm build settings: `MACOSX_DEPLOYMENT_TARGET = 13.0`, `SWIFT_VERSION = 6.0`.

---

## Phase 1: Shell Integration — `UniversalControlService.swift`

This is the foundation. Everything else depends on it being correct.

### Responsibility
- Read the current state of Universal Control keys from `com.apple.universalcontrol`
- Write new states using `defaults write`
- Restart the daemon using `pkill UniversalControl`

### Design

Use a Swift `actor` to ensure serial access to shell operations and safe state publication.

```swift
actor UniversalControlService {
    // MARK: - Public Interface
    func fetchState() async throws -> UCState
    func setUniversalControlEnabled(_ enabled: Bool) async throws
    func setMagicEdgesEnabled(_ enabled: Bool) async throws
    func setAutoReconnectEnabled(_ enabled: Bool) async throws
    func severAllConnections() async throws  // just pkill, no defaults write

    // MARK: - Private Helpers
    private func runDefaults(args: [String]) async throws -> String?
    private func restartDaemon() async throws
}

struct UCState: Sendable {
    var universalControlEnabled: Bool   // inverse of "Disable" key
    var magicEdgesEnabled: Bool          // inverse of "DisableMagicEdges" key
    var autoReconnectEnabled: Bool       // inverse of "DisableAutoConnect" key
}
```

### Shell Execution Pattern (Swift 6 safe)

All `Process()` calls **block the calling thread**, so they must run off the main actor. Since `UniversalControlService` is an `actor` (not `@MainActor`), calls will execute on a cooperative thread pool automatically.

```swift
private func runDefaults(args: [String]) async throws -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = args

    let pipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()  // blocking; safe because we're off MainActor

    guard process.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
```

**Reading a key:**
```swift
// Returns true if the "Disable" key is set to 1 (or absent = false = enabled)
let output = try await runDefaults(args: ["read", "com.apple.universalcontrol", "Disable"])
let isDisabled = output == "1"
```

**Writing a key:**
```swift
try await runDefaults(args: [
    "write", "com.apple.universalcontrol", "Disable", "-bool", enabled ? "NO" : "YES"
])
```

**Restarting the daemon:**
```swift
private func restartDaemon() async throws {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["UniversalControl"]
    try pkill.run()
    pkill.waitUntilExit()
    // Non-zero exit (process not found) is acceptable; just means daemon wasn't running
}
```

### Key Mapping

| Feature | Defaults Key | "Enabled" = | Write Value When Enabling |
|---|---|---|---|
| Universal Control | `Disable` | `false` / absent | `-bool NO` |
| Magic Edges ("Push to connect") | `DisableMagicEdges` | `false` / absent | `-bool NO` |
| Auto-Reconnect | `DisableAutoConnect` | `false` / absent | `-bool NO` |

> **Note:** All keys are "Disable" variants. UI must invert the boolean for user-facing labels (e.g., "Universal Control Enabled" maps to `Disable = false`).

### Error Handling

- `defaults read` returning non-zero exit code = key not yet written; treat as `false` (feature enabled by default)
- `pkill` returning non-zero exit code = daemon not running; acceptable, continue
- Wrap all throws in the public API; callers decide how to surface errors to the user

---

## Phase 2: Menu Bar Lifecycle — `AppDelegate.swift` + `MenuBarController.swift`

### 2.1 — Rewrite `EdgeGuardApp.swift`

Remove the default `WindowGroup`. The app has no windows.

```swift
@main
struct EdgeGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty — no windows. Menu bar is managed by AppDelegate.
        Settings { EmptyView() }
    }
}
```

> Using `Settings { }` instead of nothing at all avoids a SwiftUI warning about a `@main` App with no scenes.

### 2.2 — `AppDelegate.swift`

Responsible for: activating as an accessory app, owning the `NSStatusItem`, and coordinating with `MenuBarController`.

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var hotkeyManager: GlobalHotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock (belt-and-suspenders with LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        // Set up menu bar
        menuBarController = MenuBarController()

        // Set up global hotkey
        hotkeyManager = GlobalHotkeyManager { [weak self] in
            Task { @MainActor in
                self?.menuBarController?.toggleUniversalControl()
            }
        }
    }
}
```

### 2.3 — `MenuBarController.swift`

Owns `NSStatusItem` and the `NSMenu`. Syncs with `UniversalControlService` asynchronously.

**Icon strategy:**
- Universal Control **enabled**: standard opacity SF Symbol `cursorarrow.and.square.on.square`
- Universal Control **disabled**: same symbol with `.withSymbolConfiguration(.init(paletteColors: [.systemRed]))`, or use a `.slash` variant to indicate the locked state

**Menu structure:**

```
[✓] Universal Control Enabled            ← toggles Disable key
    Require 'Push' to Connect            ← toggles DisableMagicEdges key (only when UC enabled)
────────────────────────────────────────
    Sever All Connections                ← runs pkill immediately
────────────────────────────────────────
    Launch at Login                      ← SMAppService toggle
────────────────────────────────────────
    Quit EdgeGuard                       ← NSApp.terminate
```

**Implementation notes:**
- Build `NSMenu` programmatically (not SwiftUI Menu); simpler for a status item
- Store references to the checkbox `NSMenuItem`s so state can be updated without rebuilding the whole menu
- On launch: read current state via `UniversalControlService.fetchState()`, then update menu items and icon
- On each toggle: write new state, restart daemon, update icon — all on `Task { await ... }`

**`toggleUniversalControl()`** (called by hotkey and menu item):

```swift
func toggleUniversalControl() {
    Task {
        do {
            let currentState = try await service.fetchState()
            try await service.setUniversalControlEnabled(!currentState.universalControlEnabled)
            let newState = try await service.fetchState()
            await MainActor.run {
                self.updateMenuAndIcon(state: newState)
            }
        } catch {
            // Show error in menu or NSAlert
        }
    }
}
```

---

## Phase 3: Global Hotkey — `GlobalHotkeyManager.swift`

### Responsibilities
- Check and prompt for Accessibility permission
- Register `Cmd + Opt + Ctrl + X` global event monitor
- Call provided action closure on match
- Clean up monitor on deinit

### Implementation

```swift
@MainActor
final class GlobalHotkeyManager {
    private var monitor: Any?
    private let action: @MainActor () -> Void

    init(action: @MainActor @escaping () -> Void) {
        self.action = action
        setupMonitor()
    }

    private func setupMonitor() {
        guard checkAccessibilityPermission() else { return }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isTargetCombo = flags == [.command, .option, .control]
                && event.keyCode == 7  // 'x' key
            if isTargetCombo {
                Task { @MainActor [weak self] in self?.action() }
            }
        }
    }

    private func checkAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
```

**Key code `7` = `x` on US keyboard.** For robustness, compare `event.charactersIgnoringModifiers?.lowercased() == "x"` instead of a raw keycode.

**Permission flow:**
- On first launch without Accessibility access, `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt = true` opens System Settings directly to the Accessibility panel
- The monitor is not registered if permission is not yet granted
- Consider observing `NSWorkspace.shared.notificationCenter` for workspace activation to re-attempt registration after permission is granted

---

## Phase 4: App Settings Persistence — `AppSettings.swift`

### Responsibilities
Store **EdgeGuard's own preferences** (distinct from system state) in `UserDefaults`.

```swift
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Persisted EdgeGuard preferences
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("globalHotkeyEnabled") var globalHotkeyEnabled: Bool = true

    private init() {}
}
```

**Notes:**
- Use `@AppStorage` for SwiftUI-friendly UserDefaults binding
- `launchAtLogin` drives `SMAppService` registration (see Phase 5)
- System state (UC enabled/disabled) is NOT stored here — always read live from the system via `UniversalControlService`

---

## Phase 5: Launch at Login — via `SMAppService`

No separate file needed — handled in `AppDelegate` or a small helper.

```swift
import ServiceManagement

@MainActor
func setLaunchAtLogin(_ enabled: Bool) {
    let service = SMAppService.mainApp
    do {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
        AppSettings.shared.launchAtLogin = enabled
    } catch {
        // e.g. .launchDeniedByUser — surface this to the user
        AppSettings.shared.launchAtLogin = (service.status == .enabled)
    }
}

@MainActor
func syncLaunchAtLoginState() {
    let status = SMAppService.mainApp.status
    AppSettings.shared.launchAtLogin = (status == .enabled)
}
```

- Call `syncLaunchAtLoginState()` during `applicationDidFinishLaunching` so the menu checkbox is accurate on every launch
- Update the "Launch at Login" menu item's `state` from `AppSettings.shared.launchAtLogin`

---

## Phase 6: Delete `ContentView.swift`

The default `ContentView.swift` from the Xcode template is not needed. It can be deleted since the entire UI lives in the `NSStatusItem` menu.

If a future settings window is added, a SwiftUI view can be introduced at that time.

---

## Phase 7: Unit Tests — `EdgeGuardTests/`

### 7.1 — `UniversalControlServiceTests.swift`

Test the service with a **mock shell executor** (protocol-based seam or a subclass), so tests never actually run `defaults` or `pkill`.

```swift
// Protocol seam for testability
protocol ShellExecutor: Actor {
    func run(executable: String, arguments: [String]) async throws -> String?
}

// Production implementation wraps Process()
actor SystemShellExecutor: ShellExecutor { ... }

// Test stub returns canned values
actor MockShellExecutor: ShellExecutor {
    var stubbedOutput: [String: String] = [:]
    var capturedCommands: [(String, [String])] = []

    func run(executable: String, arguments: [String]) async throws -> String? {
        capturedCommands.append((executable, arguments))
        let key = arguments.joined(separator: " ")
        return stubbedOutput[key]
    }
}
```

**Test cases:**
- `fetchState()` with all keys absent → all enabled (defaults)
- `fetchState()` with `Disable = 1` → UC disabled
- `setUniversalControlEnabled(false)` → `defaults write ... Disable -bool YES` + `pkill`
- `setUniversalControlEnabled(true)` → `defaults write ... Disable -bool NO` + `pkill`
- `severAllConnections()` → only runs `pkill`, no defaults write

### 7.2 — `AppSettingsTests.swift`

- Verify `AppStorage` keys round-trip correctly
- Verify default values on first install

### 7.3 — `GlobalHotkeyManagerTests.swift`

Limited unit testability (NSEvent monitoring requires a running app). Consider:
- Testing key code + modifier matching logic in isolation (extract a pure function)
- Verifying the monitor is registered/unregistered correctly via a mock `NSEvent` wrapper

---

## Phase 8: UI Tests — `EdgeGuardUITests/`

UI tests for a menu bar app are limited (Xcode UI testing doesn't easily access `NSStatusItem`). Options:

1. **Smoke test**: Launch the app, assert it does NOT present a main window, assert the `NSStatusItem` appears via accessibility APIs
2. **Functional tests**: If a Settings window or popover is added, test that via `XCUIApplication`

For now, `EdgeGuardUITests.swift` and `EdgeGuardUITestsLaunchTests.swift` can be minimal launch sanity checks.

---

## Implementation Order

```
Phase 0: Project config (Info.plist, entitlements, deployment target)
Phase 1: UniversalControlService actor + shell execution + tests
Phase 2: AppDelegate + MenuBarController (NSStatusItem + NSMenu)
Phase 3: GlobalHotkeyManager (hotkey registration)
Phase 4: AppSettings (UserDefaults persistence)
Phase 5: SMAppService launch-at-login wiring
Phase 6: Delete ContentView / clean up scaffolding
Phase 7+: Tests for each phase
```

Dependencies:
- Phase 2 depends on Phase 1 (menu reads system state)
- Phase 3 depends on Phase 2 (hotkey calls menu toggle)
- Phases 4 and 5 are independent and can be done alongside Phase 2

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Service concurrency model | `actor` | Serial access to shell ops; natural Swift 6 model |
| Menu construction | Programmatic `NSMenu` | Simpler than SwiftUI `Menu` for status items |
| App Sandbox | Disabled | `pkill` and unrestricted `defaults` are required; not App Store |
| Icon disabled state | Red/slash symbol variant | Visually distinct; no extra assets needed |
| State source of truth | System (`defaults read`) | Never cache UC state; always re-read to avoid drift |
| Settings persistence | `@AppStorage` / UserDefaults | Lightweight, SwiftUI-compatible |

---

## Future Considerations (from SPEC.md Section 7)

1. **Display Detection** — Observe `NSWorkspace.shared.runningApplications` for focus changes; auto-disable UC when certain app bundle IDs (Final Cut, Photoshop) become frontmost
2. **Sidecar Specifics** — Toggle wired vs. wireless Sidecar via `com.apple.sidecar` domain preferences; add a separate "Sidecar" section to the menu
3. **Auto-Reconnect Toggle** — `DisableAutoConnect` is in the spec table but not yet in the menu; add as a third checkbox under "Advanced"
4. **Popover vs. Menu** — For a richer settings UI, replace `NSMenu` with an `NSPopover` hosting a SwiftUI `VStack` (toggle switches instead of checkboxes)
5. **Accessibility Permission Recovery** — After the user grants Accessibility, detect the grant via a timer or `DistributedNotificationCenter` and re-register the hotkey without requiring a relaunch
