//
//  VolterApp.swift
//  Volter
//
//  Created by Will on 7/4/26.
//

import SwiftUI

@main
struct VolterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?

    func applicationWillTerminate(_ notification: Notification) {
        // Tell root helper to exit and unlink socket (also exits automatically when ppid dies)
        PrivilegedHelperManager.shared.terminateHelper()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable the Dock icon
        NSApp.setActivationPolicy(.accessory)

        // Setup popover window (Matching ContentView’s 114pt height constraint)
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 290, height: 114)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover

        // Setup Menu Bar Item with lightning bolt symbol
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = self.statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Volter")
            button.action = #selector(togglePopover(_:))
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if let popover = popover {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}
