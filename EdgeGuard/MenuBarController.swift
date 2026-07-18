import AppKit
import os
import ServiceManagement

/// Owns the NSStatusItem and the NSMenu. Reads system state from UniversalControlService
/// and reflects it in the icon and menu item checkmarks.
@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let service = UniversalControlService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EdgeGuard", category: "MenuBarController")
    private var isShowingError = false
    private var syncTimer: Timer?

    // Strong references to items updated dynamically after menu is built
    private let ucItem: NSMenuItem
    private let magicEdgesItem: NSMenuItem
    private let autoReconnectItem: NSMenuItem
    private let hotkeyItem: NSMenuItem
    private let launchAtLoginItem: NSMenuItem

    weak var hotkeyManager: GlobalHotkeyManager? {
        didSet {
            refreshHotkeyItem()
        }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        ucItem = NSMenuItem(
            title: "Universal Control Enabled",
            action: #selector(handleToggleUC),
            keyEquivalent: ""
        )
        magicEdgesItem = NSMenuItem(
            title: "Require 'Push' to Connect",
            action: #selector(handleToggleMagicEdges),
            keyEquivalent: ""
        )
        autoReconnectItem = NSMenuItem(
            title: "Auto-Reconnect",
            action: #selector(handleToggleAutoReconnect),
            keyEquivalent: ""
        )
        hotkeyItem = NSMenuItem(
            title: "Global Shortcut: ⌥⌘⌃X",
            action: nil,
            keyEquivalent: ""
        )
        launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(handleToggleLaunchAtLogin),
            keyEquivalent: ""
        )

        super.init()

        statusItem.menu = buildMenu()

        // Optimistic initial state (macOS ships with UC enabled)
        ucItem.state = .on
        magicEdgesItem.state = .on
        autoReconnectItem.state = .on
        updateIcon(ucEnabled: true)

        // SMAppService is synchronously readable — seed the checkmark before the async Task fires
        syncLaunchAtLoginState()

        // Load actual UC state asynchronously
        Task { await refreshState() }

        // Polling timer to detect external preference changes
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncExternalState()
            }
        }
    }

    // MARK: - Menu Construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        ucItem.target = self
        menu.addItem(ucItem)

        // Indented to visually indicate they're sub-options of Universal Control
        magicEdgesItem.target = self
        magicEdgesItem.indentationLevel = 1
        menu.addItem(magicEdgesItem)

        autoReconnectItem.target = self
        autoReconnectItem.indentationLevel = 1
        menu.addItem(autoReconnectItem)

        menu.addItem(.separator())

        let severItem = NSMenuItem(
            title: "Sever All Connections",
            action: #selector(handleSeverAll),
            keyEquivalent: ""
        )
        severItem.target = self
        menu.addItem(severItem)

        menu.addItem(.separator())

        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        menu.addItem(.separator())

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        // Quit uses the standard NSApplication action via the responder chain
        menu.addItem(NSMenuItem(
            title: "Quit EdgeGuard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        return menu
    }

    // MARK: - State Management

    /// Reads current system state and updates the menu and icon to match.
    func refreshState() async {
        do {
            let state = try await service.fetchState()
            syncLaunchAtLoginState()
            updateMenuAndIcon(state: state)
        } catch {
            logger.error("Failed to read Universal Control state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateMenuAndIcon(state: UCState) {
        ucItem.state = state.universalControlEnabled ? .on : .off
        magicEdgesItem.state = state.magicEdgesEnabled ? .on : .off
        magicEdgesItem.isEnabled = state.universalControlEnabled
        autoReconnectItem.state = state.autoReconnectEnabled ? .on : .off
        autoReconnectItem.isEnabled = state.universalControlEnabled
        updateIcon(ucEnabled: state.universalControlEnabled)
    }

    private func updateIcon(ucEnabled: Bool) {
        let symbolName = "cursorarrow.and.square.on.square"
        if ucEnabled {
            let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "EdgeGuard: Universal Control enabled"
            )
            image?.isTemplate = true
            statusItem.button?.image = image
        } else {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "EdgeGuard: Universal Control disabled"
            )?.withSymbolConfiguration(config)
            statusItem.button?.image = image
        }
    }

    private func refreshHotkeyItem() {
        guard let hotkeyManager else { return }
        
        let hasPermission = hotkeyManager.checkAccessibilityPermission(prompt: false)
        if hasPermission {
            hotkeyItem.title = "Global Shortcut: ⌥⌘⌃X"
            hotkeyItem.image = nil
            hotkeyItem.target = nil
            hotkeyItem.action = nil
            hotkeyItem.isEnabled = false // Informational only
        } else {
            hotkeyItem.title = "⚠️ Enable Global Shortcut..."
            hotkeyItem.target = self
            hotkeyItem.action = #selector(handleRequestAccessibilityPermission)
            hotkeyItem.isEnabled = true
        }
    }

    @objc private func handleRequestAccessibilityPermission() {
        guard let hotkeyManager else { return }
        
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "EdgeGuard requires Accessibility permission to register the global keyboard shortcut (⌥⌘⌃X) for toggling Universal Control.\n\nPlease enable EdgeGuard in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Trigger the OS accessibility permission prompt
            _ = hotkeyManager.checkAccessibilityPermission(prompt: true)
            
            // Open System Settings Accessibility pane directly
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func syncExternalState() async {
        let domain = "com.apple.universalcontrol" as CFString
        
        let disableVal = CFPreferencesCopyAppValue("Disable" as CFString, domain) as? Bool
        let magicEdgesVal = CFPreferencesCopyAppValue("DisableMagicEdges" as CFString, domain) as? Bool
        let autoConnectVal = CFPreferencesCopyAppValue("DisableAutoConnect" as CFString, domain) as? Bool
        
        let liveUC = disableVal != true
        let liveMagicEdges = magicEdgesVal != true
        let liveAutoReconnect = autoConnectVal != true
        
        let currentUC = ucItem.state == .on
        let currentMagicEdges = magicEdgesItem.state == .on
        let currentAutoReconnect = autoReconnectItem.state == .on
        
        if liveUC != currentUC || liveMagicEdges != currentMagicEdges || liveAutoReconnect != currentAutoReconnect {
            await refreshState()
        }
    }

    // MARK: - Public API (called by GlobalHotkeyManager)

    func toggleUniversalControl() {
        Task {
            do {
                let current = try await service.fetchState()
                try await service.setUniversalControlEnabled(!current.universalControlEnabled)
                let updated = try await service.fetchState()
                updateMenuAndIcon(state: updated)
            } catch {
                showError(error)
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func handleToggleUC() {
        toggleUniversalControl()
    }

    @objc private func handleToggleMagicEdges() {
        Task {
            do {
                let current = try await service.fetchState()
                try await service.setMagicEdgesEnabled(!current.magicEdgesEnabled)
                let updated = try await service.fetchState()
                updateMenuAndIcon(state: updated)
            } catch {
                showError(error)
            }
        }
    }

    @objc private func handleToggleAutoReconnect() {
        Task {
            do {
                let current = try await service.fetchState()
                try await service.setAutoReconnectEnabled(!current.autoReconnectEnabled)
                let updated = try await service.fetchState()
                updateMenuAndIcon(state: updated)
            } catch {
                showError(error)
            }
        }
    }

    @objc private func handleSeverAll() {
        Task {
            do {
                try await service.severAllConnections()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func handleToggleLaunchAtLogin() {
        setLaunchAtLogin(!AppSettings.shared.launchAtLogin)
    }

    // MARK: - Launch at Login (SMAppService)

    private func setLaunchAtLogin(_ enabled: Bool) {
        let smService = SMAppService.mainApp
        do {
            if enabled {
                try smService.register()
            } else {
                try smService.unregister()
            }
            AppSettings.shared.launchAtLogin = enabled
            launchAtLoginItem.state = enabled ? .on : .off
        } catch {
            // Registration may be denied by the user; sync back the real state
            syncLaunchAtLoginState()
        }
    }

    private func syncLaunchAtLoginState() {
        let isEnabled = SMAppService.mainApp.status == .enabled
        AppSettings.shared.launchAtLogin = isEnabled
        launchAtLoginItem.state = isEnabled ? .on : .off
    }

    // MARK: - Error Handling

    private func showError(_ error: Error) {
        logger.error("EdgeGuard action failed: \(error.localizedDescription, privacy: .public)")
        guard !isShowingError else { return }
        isShowingError = true
        let alert = NSAlert()
        alert.messageText = "EdgeGuard Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
        isShowingError = false
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let hotkeyManager {
            _ = hotkeyManager.tryEnable()
        }
        refreshHotkeyItem()
    }
}
