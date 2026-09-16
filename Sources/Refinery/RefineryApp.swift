import AppKit
import SwiftUI

@main
struct RefineryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Settings {
            SettingsView(model: model)
                .frame(minWidth: 420, minHeight: 480)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Smoke-test mode: run the e2e pipeline instead of the menu bar.
        if ProcessInfo.processInfo.environment["E2E_BASE_URL"] != nil {
            E2E.run()
        }

        // The SwiftUI scene hosts the settings window; the menu-bar item is manual.
        let model = AppModel()
        self.model = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Refinery")
        item.button?.image?.size = NSSize(width: 18, height: 18)
        self.statusItem = item

        let menu = NSMenu()
        let contentView = MenuBarView(model: model)
        let topView = NSHostingView(rootView: contentView)
        let topItem = NSMenuItem()
        topItem.view = topView
        menu.addItem(topItem)
        item.menu = menu

        model.setTrigger { [weak model] in
            model?.handleHotkey()
        }
        model.applyHotkey()
    }
}
