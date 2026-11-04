import AppKit
import SwiftUI

/// A transparent view over the menu bar icon: files dropped on the icon go straight into the basket.
final class StatusDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    /// Clicks pass to the real button underneath.
    override func mouseDown(with event: NSEvent) { (superview as? NSStatusBarButton)?.performClick(nil) }
}

/// Menu bar icon with the basket, and a quiet background mode: with no window open the app drops
/// out of the Dock and does nothing until a disk is mounted or the user comes back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Cesto di FCP Toolbox")
            image?.isTemplate = true  // drawn black on a light menu bar, white on a dark one
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onDrop = { [weak self] urls in
                Basket.shared.add(urls)
                self?.showPopover()
            }
            button.addSubview(drop)
        }
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.contentViewController = NSHostingController(
            rootView: BasketView(basket: .shared, model: .shared,
                                 openMain: { [weak self] in self?.openMainWindow() },
                                 quit: { NSApp.terminate(nil) })
                .preferredColorScheme(.dark))

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.settleIntoBackgroundIfNoWindows() }
        }
        PreviewHub.shared.install()
        AutomationRunner.start()
        if CommandLine.arguments.contains("--basket") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showPopover() }
        }
    }

    /// Files opened with the app, and `fcptoolbox://tool/<id>?file=…` links (Finder quick actions).
    func application(_ application: NSApplication, open urls: [URL]) {
        openMainWindow()
        Model.shared.handleExternal(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func settleIntoBackgroundIfNoWindows() {
        let open = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        if !open { NSApp.setActivationPolicy(.accessory) }
    }

    private func openMainWindow() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Sends the "reopen" event, which makes SwiftUI create the window again.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
