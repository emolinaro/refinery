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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var settingsPopover: NSPopover?
    private var pendingSettings = false

    private let menuWidth: CGFloat = 300
    private let menuMinimumHeight: CGFloat = 340
    private var menuContentView: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Refinery")
        item.button?.image?.size = NSSize(width: 18, height: 18)
        statusItem = item

        // Quick actions stay in the dropdown; Settings opens a popover because
        // menu tracking steals keyboard focus from menu-item views, making text
        // entry (endpoint URL, model, API key) impossible inside the menu.
        let menu = NSMenu()
        menu.delegate = self
        let topItem = NSMenuItem()
        let content = NSHostingView(rootView: MenuBarView(model: model) { [weak self] in
            // Mark that Settings should open, then end menu tracking:
            // a click inside a hosted view does not dismiss the menu, and a
            // popover shown while tracking is active is dismissed with it.
            self?.pendingSettings = true
            self?.statusItem?.menu?.cancelTracking()
        }.frame(width: menuWidth))
        // Explicit non-zero frame: NSMenu measures items during tracking and a
        // zero-height measurement makes the menu lay out empty and dismiss
        // (AppKit logs "A menu item's height should never be 0").
        content.frame = NSRect(x: 0, y: 0, width: menuWidth, height: menuMinimumHeight)
        menuContentView = content
        topItem.view = content
        menu.addItem(topItem)
        item.menu = menu

        model.setTrigger { [weak model] in
            model?.handleHotkey()
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Force Quit can interrupt restoration because clipboard contents are never persisted.
        guard model.deferTerminationUntilClipboardRestored({ shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }) else {
            return .terminateNow
        }
        return .terminateLater
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // The menu's height must follow its content: the accessibility
        // status messages wrap to multiple lines, and the fixed hosting
        // frame would clip the Quit button off the bottom of the menu.
        guard let content = menuContentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(menuMinimumHeight, content.intrinsicContentSize.height)
        content.setFrameSize(NSSize(width: menuWidth, height: height))
        content.layoutSubtreeIfNeeded()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard pendingSettings else { return }
        pendingSettings = false
        // Run on the next runloop turn so the menu's tracking session has
        // fully ended before the popover takes focus.
        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }

    private func openSettings() {
        guard let item = statusItem, let button = item.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: SettingsView(model: model)
                .frame(width: 380)
                .padding(8)
        )
        popover.contentSize = NSSize(width: 396, height: 480)
        settingsPopover = popover

        // Note: NSApp.activate here races the menu teardown and can close a
        // .transient popover; the popover itself takes focus when shown.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              popover === settingsPopover else { return }
        model.cancelHotkeyRecording()
        settingsPopover = nil
    }
}
