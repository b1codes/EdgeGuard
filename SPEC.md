# Project Specification: EdgeGuard

**Project Name:** EdgeGuard
**Target Platform:** macOS 13.0+
**Description:** A lightweight macOS menu bar utility designed to give users granular control over Universal Control and Sidecar transitions, preventing accidental cursor "drift" to adjacent iPads or Macs.

---

## 1. Objectives
* Provide a **one-click toggle** in the macOS menu bar to enable/disable Universal Control.
* Allow users to toggle the "Push through edge to connect" feature without digging through System Settings.
* Implement a global keyboard shortcut for emergency disconnection.

## 2. Technical Stack
* **Language:** Swift 6.0
* **Framework:** SwiftUI / AppKit (`NSStatusItem`)
* **Persistence:** `UserDefaults` for app settings; `com.apple.universalcontrol` for system overrides.
* **Execution:** `Process()` (NSTask) to interface with the system `defaults` binary and `pkill`.

## 3. Core Features & Functional Requirements

### 3.1 Menu Bar Interface
* **Status Icon:** A custom SF Symbol (e.g., `display.and.arrow.down` or `cursorarrow.and.square.on.square`).
* **Primary Toggle:** "Enable Universal Control" (Checkbox).
* **Advanced Toggle:** "Require 'Push' to Connect" (Checkbox).
    * *Note: This toggles the `DisableMagicEdges` key.*
* **Quick Disconnect:** "Sever All Connections" (Immediate `pkill`).
* **Settings/Quit:** Standard app management options.

### 3.2 System Interaction Layer
The app must execute the following commands with appropriate permissions:

| Action | Domain | Key | Value |
| :--- | :--- | :--- | :--- |
| **Toggle Universal Control** | `com.apple.universalcontrol` | `Disable` | `bool` (true/false) |
| **Toggle Magic Edges** | `com.apple.universalcontrol` | `DisableMagicEdges` | `bool` (true/false) |
| **Toggle Auto-Reconnect** | `com.apple.universalcontrol` | `DisableAutoConnect` | `bool` (true/false) |

> **Warning:** After writing to `defaults`, the app must restart the `UniversalControl` background process for changes to take effect immediately.

### 3.3 Keyboard Shortcuts
* Support for a global hotkey (e.g., `Cmd + Opt + Ctrl + X`) to toggle the "Disable" state.
* Implementation via `NSEvent.addGlobalMonitorForEvents`.

---

## 4. UI/UX Design
* **Behavior:** The app should be "Menu Bar only" (no Dock icon).
* **State Feedback:** The menu bar icon should change opacity or color when Universal Control is disabled to provide a visual "locked" status.
* **Launch at Login:** Include a toggle to add the app to Login Items via `SMAppService`.

---

## 5. Implementation Roadmap

### Phase 1: Shell Integration
* Verify `defaults write` commands work within the app sandbox.
* *Note: This may require the `com.apple.security.temporary-exception.shared-preference.read-write` entitlement for the specific domain.*

### Phase 2: Menu Bar Lifecycle
* Setup `NSStatusBar` and `NSStatusItem`.
* Create a SwiftUI-based `Menu` or `Popover` for the settings.

### Phase 3: Daemon Management
* Refine the `pkill` logic. Ensure that killing the process doesn't cause system instability (the daemon is designed to auto-restart).

---

## 6. Permissions & Sandbox
Because this app modifies system-level preferences, it may require:
1.  **App Sandbox:** Disabled, or configured with specific temporary exceptions.
2.  **Accessibility Permissions:** Required if implementing certain types of global hotkeys.

---

## 7. Future Considerations
* **Display Detection:** Automatically disable Universal Control when specific high-precision apps (e.g., Photoshop, Final Cut) are in the foreground.
* **Sidecar Specifics:** Adding a toggle for wired vs. wireless Sidecar preference.
