import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var hotkeyManager: GlobalHotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with LSUIElement in Info.plist
        NSApp.setActivationPolicy(.accessory)

        let controller = MenuBarController()
        menuBarController = controller

        let manager = GlobalHotkeyManager { [weak self] in
            self?.menuBarController?.toggleUniversalControl()
        }
        hotkeyManager = manager
        controller.hotkeyManager = manager
    }
}
