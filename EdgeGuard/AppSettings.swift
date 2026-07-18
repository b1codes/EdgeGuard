import Foundation

/// Stores EdgeGuard's own preferences in UserDefaults.
/// System state (UC on/off) is NOT stored here — always read live from UniversalControlService.
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: "launchAtLogin") }
        set { UserDefaults.standard.set(newValue, forKey: "launchAtLogin") }
    }

    var globalHotkeyEnabled: Bool {
        get {
            // Returns false when key is absent; default should be true, so check explicitly.
            guard UserDefaults.standard.object(forKey: "globalHotkeyEnabled") != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: "globalHotkeyEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "globalHotkeyEnabled") }
    }

    private init() {}
}

import AppKit

/// EdgeGuard Design System Token constants mapped from DESIGN.md.
enum DesignSystem {
    enum Colors {
        /// Core Thermal Heat (#FF3B30) - Primary status color
        static let primary = NSColor(red: 255/255, green: 59/255, blue: 48/255, alpha: 1.0)
        /// Corona Thermal Heat (#FF9500) - Accent / Transition color
        static let accent = NSColor(red: 255/255, green: 149/255, blue: 0/255, alpha: 1.0)
        /// Glass Base (5% white)
        static let glassBase = NSColor(white: 1.0, alpha: 0.05)
        /// Glass Border (20% white)
        static let glassBorder = NSColor(white: 1.0, alpha: 0.2)
    }
}
