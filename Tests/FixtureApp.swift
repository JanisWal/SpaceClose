import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var confirm: NSButton!
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem(title: "SpaceClose-Test", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "SpaceClose-Test")
        let quit = NSMenuItem(title: "Testfenster beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit); menu.addItem(item); menu.setSubmenu(appMenu, for: item)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SpaceClose-Test – ohne Dateien"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 440))
        let text = NSTextField(wrappingLabelWithString: "SpaceClose-Testfenster\n\nDieses eigens erstellte Fenster enthält keine Dateien oder ungespeicherten Nutzerdaten. Es dient nur zur Prüfung des Schließens aus Mission Control.")
        text.frame = NSRect(x: 40, y: 190, width: 620, height: 190)
        text.font = .systemFont(ofSize: 22)
        text.autoresizingMask = [.width, .minYMargin]
        content.addSubview(text)
        confirm = NSButton(checkboxWithTitle: "Beim Schließen eine Test-Rückfrage anzeigen", target: nil, action: nil)
        confirm.frame = NSRect(x: 40, y: 130, width: 620, height: 32)
        confirm.state = .on
        confirm.autoresizingMask = [.width, .minYMargin]
        content.addSubview(confirm)
        let overview = NSButton(title: "Vollbildübersicht zum Test öffnen", target: self, action: #selector(openOverview))
        overview.bezelStyle = .rounded
        overview.frame = NSRect(x: 40, y: 70, width: 320, height: 36)
        overview.autoresizingMask = [.minYMargin]
        content.addSubview(overview)
        window.contentView = content
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.window.toggleFullScreen(nil) }
    }
    @objc func openOverview() {
        typealias Notify = @convention(c) (CFString, Int32) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY), let pointer = dlsym(handle, "CoreDockSendNotification") else { return }
        let notify = unsafeBitCast(pointer, to: Notify.self)
        _ = notify("com.apple.expose.awake" as CFString, 0)
    }
    func confirmation() -> Bool {
        guard confirm.state == .on else { return true }
        let alert = NSAlert()
        alert.messageText = "SpaceClose-Test bestätigen"
        alert.informativeText = "Dies ist nur eine Test-Rückfrage. Das Testfenster enthält keine Dateien."
        alert.addButton(withTitle: "Testfenster schließen")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmation() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window.isVisible && !confirmation() ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
