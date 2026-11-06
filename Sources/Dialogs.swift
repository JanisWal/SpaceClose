import AppKit
import ApplicationServices

struct BlockingDialog {
    let element: AXUIElement
    let window: AXUIElement
    var focusedSemantic = false
    var id: UInt { CFHash(element) }
}

extension MissionReader {
    // Observe real blocking UI only after an accepted close request. A dialog
    // need not have a new AX identity: Office may reuse an existing UI object.
    func dialogs(for target: AppTarget, wholeApp: Bool) -> [BlockingDialog] {
        let root = AXUIElementCreateApplication(target.pid)
        let rootData = AX.attributes(root, [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute], timeout: 0.12)
        let windows = rootData[kAXWindowsAttribute] as? [AXUIElement] ?? []
        let focusedWindow = AX.asElement(rootData[kAXFocusedWindowAttribute])
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        var found: [BlockingDialog] = []
        func belongs(_ window: AXUIElement) -> Bool {
            wholeApp || AX.windowID(window).map { target.windowIDs.contains($0) } == true
        }
        func append(_ node: AXUIElement, window: AXUIElement, data: [String: CFTypeRef], focused: Bool) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == target.pid,
                  (data["AXHidden"] as? Bool) != true,
                  DialogRules.isBlocking(role: data[kAXRoleAttribute] as? String ?? "",
                    modal: data[kAXModalAttribute] as? Bool,
                    subrole: data[kAXSubroleAttribute] as? String ?? "", focused: focused),
                  !found.contains(where: { CFEqual($0.element, node) }) else { return }
            found.append(BlockingDialog(element: node, window: window, focusedSemantic: focused))
        }
        func visitWindow(_ window: AXUIElement, focused: Bool) {
            guard belongs(window), ProcessInfo.processInfo.systemUptime < deadline else { return }
            let data = AX.attributes(window, [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXWindowAttribute, "AXSheets", "AXHidden"])
            let parent = data[kAXRoleAttribute] as? String == kAXSheetRole ? AX.asElement(data[kAXWindowAttribute]) ?? window : window
            append(window, window: parent, data: data, focused: focused)
            for sheet in (data["AXSheets"] as? [AXUIElement] ?? []) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                append(sheet, window: window, data: AX.attributes(sheet,
                    [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, "AXHidden"]), focused: focused)
                if !found.isEmpty { break }
            }
        }
        if let focusedWindow { visitWindow(focusedWindow, focused: true) }
        if !found.isEmpty { return found }
        // A custom Office prompt may be nested under an AXGroup, not AXSheets.
        // Follow the focused control's parents; never traverse the document tree.
        var node = AX.asElement(rootData[kAXFocusedUIElementAttribute])
        var seen: Set<UInt> = []
        let ancestryDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.12)
        for _ in 0..<8 {
            guard let current = node, seen.insert(CFHash(current)).inserted,
                  ProcessInfo.processInfo.systemUptime < ancestryDeadline else { break }
            let data = AX.attributes(current, [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute,
                kAXParentAttribute, kAXWindowAttribute, "AXHidden"])
            let role = data[kAXRoleAttribute] as? String ?? ""
            if let window = role == kAXWindowRole ? current : AX.asElement(data[kAXWindowAttribute]), belongs(window) {
                append(current, window: window, data: data, focused: true)
                if !found.isEmpty { return found }
            }
            if role == kAXWindowRole { break }
            node = AX.asElement(data[kAXParentAttribute])
        }
        // Rotate through other windows so a long list cannot permanently hide
        // a prompt near its end behind a per-scan time budget.
        if !windows.isEmpty {
            let start = dialogScanOffsets[target.pid, default: 0] % windows.count
            for step in 0..<windows.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let index = (start + step) % windows.count
                dialogScanOffsets[target.pid] = (index + 1) % windows.count
                let window = windows[index]
                if let focusedWindow, CFEqual(window, focusedWindow) { continue }
                visitWindow(window, focused: false)
                if !found.isEmpty { break }
            }
        }
        return found
    }

    func dialogIsPresent(_ dialog: BlockingDialog, target: AppTarget) -> Bool {
        var pid: pid_t = 0
        let data = AX.attributes(dialog.element, [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, "AXHidden"])
        guard AXUIElementGetPid(dialog.element, &pid) == .success, pid == target.pid,
              let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == target.bundleID, !app.isTerminated,
              (data["AXHidden"] as? Bool) != true,
              DialogRules.isBlocking(role: data[kAXRoleAttribute] as? String ?? "",
                modal: data[kAXModalAttribute] as? Bool,
                subrole: data[kAXSubroleAttribute] as? String ?? "", focused: dialog.focusedSemantic) else { return false }
        return true
    }

    func raiseDialog(_ dialog: BlockingDialog, target: AppTarget) {
        guard dialogIsPresent(dialog, target: target) else { return }
        let root = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        AXUIElementSetMessagingTimeout(dialog.window, 0.15)
        AXUIElementSetMessagingTimeout(dialog.element, 0.15)
        _ = AXUIElementPerformAction(dialog.window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, dialog.window)
        _ = AXUIElementPerformAction(dialog.element, kAXRaiseAction as CFString)
    }
}
