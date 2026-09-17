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
        topItem.view = NSHostingView(rootView: MenuBarView(model: model))
        menu.addItem(topItem)
        item.menu = menu

        model.setTrigger { [weak model] in
            model?.handleHotkey()
        }
    }
}
