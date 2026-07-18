import AppKit

/// Registers a global ⌘⌥⌃X keyboard shortcut and fires an action closure on match.
/// Works when the app is both active (local monitor) and inactive (global monitor).
@MainActor
final class GlobalHotkeyManager {
    // nonisolated(unsafe) so deinit (non-isolated) can remove monitors safely.
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?
    private let action: @MainActor () -> Void

    init(action: @MainActor @escaping () -> Void) {
        self.action = action
        _ = tryEnable()
    }

    /// Checks accessibility permission and registers monitors if granted.
    /// Returns true if monitors are active, false otherwise.
    @discardableResult
    func tryEnable() -> Bool {
        guard globalMonitor == nil else { return true }
        
        guard checkAccessibilityPermission(prompt: false) else { return false }
        
        setupMonitors()
        return true
    }

    private func setupMonitors() {
        // Global monitor for when other applications are active
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Local monitor for when EdgeGuard itself is active (e.g. menu is open, alerts shown)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let matched = self.handleKeyEvent(event)
            // If matched, swallow the event so it doesn't trigger system beeps/actions
            return matched ? nil : event
        }
    }

    /// Processes keyboard events, returning true if the target shortcut is matched.
    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Strip out Caps Lock (alphaShift) and other non-modifier keys to prevent lockout
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
            .subtracting(.numericPad)
            .subtracting(.function)
        
        let char = event.charactersIgnoringModifiers?.lowercased()
        let isTargetCombo = flags == [.command, .option, .control] && char == "x"
        
        if isTargetCombo {
            Task { @MainActor [weak self] in
                self?.action()
            }
            return true
        }
        return false
    }

    /// Returns whether Accessibility is granted.
    /// If `prompt` is true, displays the OS permission dialog on denial.
    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        if prompt {
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let opts = [key: kCFBooleanTrue] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        } else {
            return AXIsProcessTrusted()
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
