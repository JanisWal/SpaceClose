import AppKit
import ApplicationServices

// Development-only, read-only observation of this utility's input geometry.
// No titles, screenshots, clicks or window actions are collected or generated.
func runLayoutDiagnostics() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let reader = MissionReader()
    let end = Date(timeIntervalSinceNow: 50)
    var previous = ""
    func rect(_ frame: CGRect?) -> Any {
        guard let frame else { return NSNull() }
        return [frame.minX, frame.minY, frame.width, frame.height]
    }
    while Date() < end {
        let screens = ScreenRecord.capture()
        let lists = reader.lists()
        let data: [String: Any] = [
            "screens": screens.map { ["id": $0.id, "frame": rect($0.frame)] },
            "lists": lists.map { list in ["display": list.displayID as Any? ?? NSNull(),
                "buttons": list.buttons.map { button in ["raw": rect(AX.frame(button)), "preview": rect(AX.spaceFrame(button)),
                    "children": AX.elements(button).map { child in ["role": AX.text(child, kAXRoleAttribute), "frame": rect(AX.frame(child))] }] }] }
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let line = String(data: json, encoding: .utf8), line != previous {
            print(line)
            fflush(stdout)
            previous = line
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }
}
