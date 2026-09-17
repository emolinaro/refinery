import AppKit
import Refinery
import SwiftUI

@main
struct RefineryApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Refinery")
        item.button?.image?.size = NSSize(width: 18, height: 18)
        statusItem = item

        let menu = NSMenu()
        let topItem = NSMenuItem()
        // Give the hosted view an explicit non-zero size: NSMenu measures items
        // during tracking and a zero-height measurement makes the whole menu
        // lay out empty and instantly dismiss (AppKit logs "A menu item's height
        // should never be 0"). An explicit frame keeps the measurement non-zero
        // before SwiftUI's first layout pass completes.
        let content = NSHostingView(rootView: MenuBarView(model: model))
        content.frame = NSRect(x: 0, y: 0, width: 380, height: 560)
        topItem.view = content
        menu.addItem(topItem)
        item.menu = menu

        model.setTrigger { [weak model] in
            model?.handleHotkey()
        }
    }
}
