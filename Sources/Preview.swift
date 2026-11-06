import AppKit
import SwiftUI

func renderSettingsPreview(path: String, dark: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let preferences = Preferences()
    preferences.trusted = true
    preferences.status = "Bereit – Mission Control öffnen"
    let view = SettingsView(preferences: preferences)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.controlActiveState, .active)
        .frame(width: 560, height: 960)
    let controller = NSHostingController(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 960),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 560, height: 960))
    // This window is never ordered on screen. Only this app's own view is rendered.
    let content = controller.view
    content.frame = NSRect(x: 0, y: 0, width: 560, height: 960)
    content.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        fputs("Vorschau konnte nicht gerendert werden.\n", stderr); exit(1)
    }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try data.write(to: URL(fileURLWithPath: path)); print("Vorschau: \(path)") }
    catch { fputs("Vorschau konnte nicht geschrieben werden.\n", stderr); exit(1) }
}
