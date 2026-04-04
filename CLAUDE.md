# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

EdgeGuard is a macOS 13.0+ menu bar utility (Swift 6.0 / SwiftUI + AppKit) that gives users granular control over Universal Control and Sidecar transitions, preventing accidental cursor "drift" to adjacent iPads or Macs.

## Build & Run

This is an Xcode project. Once the `.xcodeproj` exists:

```bash
# Build from command line
xcodebuild -scheme EdgeGuard -configuration Debug build

# Run tests
xcodebuild -scheme EdgeGuard -configuration Debug test

# Run a single test class
xcodebuild -scheme EdgeGuard -configuration Debug test -only-testing:EdgeGuardTests/MyTestClass

# Open in Xcode
open EdgeGuard.xcodeproj
```

## Architecture

### App Lifecycle
- Menu bar only app — no Dock icon (`LSUIElement = YES` in Info.plist, `NSApplicationActivationPolicy.accessory`)
- Entry point sets up `NSStatusBar` / `NSStatusItem` with a custom SF Symbol icon that changes appearance when Universal Control is disabled

### System Interaction Layer (`UniversalControlService` or similar)
The core of the app shells out to `defaults` and `pkill` via `Process()` (NSTask):

| Action | Domain | Key | Value |
|---|---|---|---|
| Toggle Universal Control | `com.apple.universalcontrol` | `Disable` | bool |
| Toggle Magic Edges ("Push to Connect") | `com.apple.universalcontrol` | `DisableMagicEdges` | bool |
| Toggle Auto-Reconnect | `com.apple.universalcontrol` | `DisableAutoConnect` | bool |

After any `defaults write`, the app must `pkill UniversalControl` to restart the background daemon for changes to take effect immediately.

### Permissions & Sandbox
- App Sandbox must be **disabled** or use the `com.apple.security.temporary-exception.shared-preference.read-write` entitlement for the `com.apple.universalcontrol` domain
- Global hotkey (`Cmd+Opt+Ctrl+X`) uses `NSEvent.addGlobalMonitorForEvents`, which requires Accessibility permission
- Launch at Login uses `SMAppService`

### Persistence
- App settings stored in `UserDefaults`
- System state read/written to `com.apple.universalcontrol` domain via `defaults` CLI

## Key Spec Reference

See `SPEC.md` for the full feature spec, including the implementation roadmap (Phase 1: shell integration → Phase 2: menu bar lifecycle → Phase 3: daemon management) and future considerations (display detection, Sidecar specifics).
