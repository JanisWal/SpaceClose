import AppKit
import ApplicationServices
import Darwin

// Private APIs resolved at runtime. Space reads, native overview toggles and
// exclusion tags for our own windows only; missing symbols disable that feature.
// No injection, no system modifications and no change to SIP are involved.
final class SpaceReader {
    typealias Connection = @convention(c) () -> Int32
    typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias Windows = @convention(c) (Int32, UInt32, CFArray, UInt32,
        UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    typealias Notify = @convention(c) (CFString, Int32) -> Int32
    typealias WindowTags = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt64>, Int32) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let displays: Displays?
    private let windows: Windows?
    private let notify: Notify?
    private let setWindowTags: WindowTags?
    private let getWindowTags: WindowTags?
    var available: Bool { connection != nil && displays != nil && windows != nil }
    var refreshAvailable: Bool { notify != nil }
    var overlayTaggingAvailable: Bool { setWindowTags != nil && getWindowTags != nil }

    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let process = dlopen(nil, RTLD_LAZY)
        handle = library
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let library, let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        connection = symbol("SLSMainConnectionID", Connection.self)
        displays = symbol("SLSCopyManagedDisplaySpaces", Displays.self)
        windows = symbol("SLSCopyWindowsWithOptionsAndTags", Windows.self)
        setWindowTags = symbol("SLSSetWindowTags", WindowTags.self)
        getWindowTags = symbol("SLSGetWindowTags", WindowTags.self)
        if let pointer = library.flatMap({ dlsym($0, "CoreDockSendNotification") })
            ?? process.flatMap({ dlsym($0, "CoreDockSendNotification") }) {
            notify = unsafeBitCast(pointer, to: Notify.self)
        } else { notify = nil }
    }

    struct Display {
        let uuid: String
        let spaces: [SpaceRecord]
    }
    func readDisplays() -> [Display] {
        guard let connection, let displays,
              let result = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return result.compactMap { item in
            guard let uuid = item["Display Identifier"] as? String,
                  let raw = item["Spaces"] as? [[String: Any]] else { return nil }
            let records = raw.compactMap { space -> SpaceRecord? in
                guard let id = (space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber,
                      let type = space["type"] as? NSNumber else { return nil }
                return SpaceRecord(id: id.uint64Value, type: type.intValue)
            }
            // A partially parsed list is unsafe to associate by position.
            guard records.count == raw.count else { return nil }
            return Display(uuid: uuid, spaces: records)
        }
    }
    func windowIDs(in space: UInt64) -> Set<CGWindowID> {
        windowIDsResult(in: space) ?? []
    }
    func windowIDsResult(in space: UInt64) -> Set<CGWindowID>? {
        guard let connection, let windows else { return nil }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaces = [NSNumber(value: space)] as CFArray
        guard let array = windows(connection(), 0, spaces, 0x7, &setTags, &clearTags)?
            .takeRetainedValue() as? [NSNumber] else { return nil }
        return Set(array.map { $0.uint32Value })
    }
    func toggleMissionControl() -> Bool {
        guard let notify else { return false }
        return notify("com.apple.expose.awake" as CFString, 0) == 0
    }
    func excludeOwnOverlayFromPreviews(windowID: CGWindowID) -> Bool {
        guard let connection, let setWindowTags else { return false }
        // SkyLight high-word flags: AvoidsCapture (bit 6), IgnoreForExpose (bit 7).
        // Only the calling process's own overlay windows are passed here.
        var requested: UInt64 = (UInt64(1) << 38) | (UInt64(1) << 39)
        return setWindowTags(connection(), windowID, &requested, 64) == 0
    }
    func ownOverlayIsExcluded(windowID: CGWindowID) -> Bool {
        guard let connection, let getWindowTags else { return false }
        let requested: UInt64 = (UInt64(1) << 38) | (UInt64(1) << 39)
        var actual: UInt64 = 0
        let getResult = getWindowTags(connection(), windowID, &actual, 64)
        return getResult == 0 && actual & requested == requested
    }
}

enum AX {
    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    static func text(_ element: AXUIElement, _ key: String) -> String {
        value(element, key) as? String ?? ""
    }
    static func elements(_ element: AXUIElement, _ key: String = kAXChildrenAttribute) -> [AXUIElement] {
        value(element, key) as? [AXUIElement] ?? []
    }
    static func asElement(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let raw = value(element, key), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    static func attributes(_ element: AXUIElement, _ keys: [String], timeout: Float = 0.08) -> [String: CFTypeRef] {
        AXUIElementSetMessagingTimeout(element, timeout)
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard error == .success, let values = raw as? [CFTypeRef], values.count == keys.count else {
            // Older third-party AX bridges may not implement the bulk call.
            if error == .notImplemented { return Dictionary(uniqueKeysWithValues: keys.compactMap { key in value(element, key).map { (key, $0) } }) }
            return [:]
        }
        var result: [String: CFTypeRef] = [:]
        for (key, item) in zip(keys, values) {
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { continue }
            result[key] = item
        }
        return result
    }
    static func frame(_ attributes: [String: CFTypeRef]) -> CGRect? {
        guard let p = attributes[kAXPositionAttribute], CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attributes[kAXSizeAttribute], CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        frame(attributes(element, [kAXPositionAttribute, kAXSizeAttribute]))
    }
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let pointer = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(pointer, to: GetWindow.self)
    }()
    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        AXUIElementSetMessagingTimeout(window, 0.08)
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(window, &id) == .success && id != 0 ? id : nil
    }
    static func spaceFrame(_ element: AXUIElement) -> CGRect? {
        guard let raw = frame(element) else { return nil }
        return LayoutRules.spaceFrame(center: raw.origin, size: raw.size)
    }
}

struct ScreenRecord {
    let id: CGDirectDisplayID
    let uuid: String
    let frame: CGRect
    static func matching(_ screens: [ScreenRecord], displayID: CGDirectDisplayID?, point: CGPoint) -> ScreenRecord? {
        let matches = screens.filter { screen in
            if let displayID { return screen.id == displayID }
            return screen.frame.contains(point)
        }
        return matches.count == 1 ? matches.first : nil
    }
    static func capture() -> [ScreenRecord] {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return ScreenRecord(id: number.uint32Value, uuid: CFUUIDCreateString(nil, uuid) as String,
                frame: LayoutRules.cocoaFrame(screen.frame, primaryTop: primaryTop))
        }
    }
}

final class MissionReader {
    let spaces = SpaceReader()
    var dialogScanOffsets: [pid_t: Int] = [:]
    private var owners: [NSRunningApplication] = []
    private var lastOwnerRefresh: TimeInterval = 0

    struct SpaceList {
        let displayID: CGDirectDisplayID?
        let buttons: [AXUIElement]
    }
    private struct ListPath {
        let owner: pid_t
        let nodes: [AXUIElement]
        let display: CGDirectDisplayID?
    }
    private var listPaths: [ListPath] = []
    func invalidateLayoutCache() { listPaths.removeAll(); targetCacheTime = -10 }
    // Reuse only paths whose parent/child links still exist in the current AX
    // tree. A cached rectangle alone is never evidence of visible Mission Control.
    func lists() -> [SpaceList] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastOwnerRefresh > 3 || owners.isEmpty || owners.contains(where: \.isTerminated) {
            owners = NSWorkspace.shared.runningApplications.filter {
                ["com.apple.dock", "com.apple.WindowManager"].contains($0.bundleIdentifier ?? "")
                || $0.executableURL?.lastPathComponent == "WindowManager"
            }
            lastOwnerRefresh = now
        }
        if !listPaths.isEmpty {
            var cached: [SpaceList] = []
            for path in listPaths {
                var parent = AXUIElementCreateApplication(path.owner)
                var valid = true
                for child in path.nodes {
                    if !AX.elements(parent).contains(where: { CFEqual($0, child) }) { valid = false; break }
                    parent = child
                }
                guard valid else { cached.removeAll(); break }
                let buttons = AX.elements(parent)
                guard !buttons.isEmpty else { cached.removeAll(); break }
                cached.append(SpaceList(displayID: path.display, buttons: buttons))
            }
            if cached.count == listPaths.count { return cached }
            listPaths.removeAll()
        }
        var found: [SpaceList] = []
        // Breadth first: do not walk every Dock icon before reaching the mc root.
        for owner in owners {
            let root = AXUIElementCreateApplication(owner.processIdentifier)
            var queue: [(AXUIElement, [AXUIElement], CGDirectDisplayID?)] = [(root, [], nil)]
            var head = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while head < queue.count && head < 120 && ProcessInfo.processInfo.systemUptime < deadline {
                let (node, route, inheritedDisplay) = queue[head]; head += 1
                let data = AX.attributes(node, [kAXIdentifierAttribute, "AXDisplayID", kAXRoleAttribute], timeout: 0.04)
                let identifier = data[kAXIdentifierAttribute] as? String ?? ""
                let display = (data["AXDisplayID"] as? NSNumber)?.uint32Value ?? inheritedDisplay
                if identifier == "mc.spaces.list" {
                    let children = AX.elements(node)
                    if !children.isEmpty {
                        found.append(SpaceList(displayID: display, buttons: children))
                        listPaths.append(ListPath(owner: owner.processIdentifier, nodes: route, display: display))
                    }
                    continue
                }
                if identifier == "mc.windows" || identifier == "mc.spaces.add" { continue }
                let role = data[kAXRoleAttribute] as? String ?? ""
                if role == "AXDockItem" { continue }
                if owner.bundleIdentifier == "com.apple.dock", role == kAXListRole,
                   !identifier.hasPrefix("mc"), !route.isEmpty { continue }
                guard route.count < 8 else { continue }
                let children = AX.elements(node)
                let next = children.map { ($0, route + [$0], display) }
                if identifier == "mc" || identifier.hasPrefix("mc.") { queue.insert(contentsOf: next, at: head) }
                else { queue.append(contentsOf: next) }
            }
        }
        return found
    }

    struct Snapshot {
        let tiles: [CloseTile]
        let message: String
    }
    private var targetCache: [UInt64: [AppTarget]] = [:]
    private var targetCacheTime: TimeInterval = -10
    func targets(in spaceID: UInt64, catalog: WindowCatalog? = nil) -> [AppTarget] {
        let ids = spaces.windowIDs(in: spaceID)
        let catalog = catalog ?? WindowCatalog(rows: (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? [])
        return catalog.owners(of: ids).compactMap { pid, ids -> AppTarget? in
            guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular, !app.isTerminated,
                  let bundle = app.bundleIdentifier else { return nil }
            return AppTarget(pid: pid, bundleID: bundle, name: app.localizedName ?? "App", windowIDs: ids)
        }.sorted { $0.pid < $1.pid }
    }
    func isCurrentTarget(_ target: AppTarget, tile: CloseTile, screenUUID: String?) -> Bool {
        // A native context menu may dismiss Mission Control. Validate the actual
        // space and process instead of depending on the continued presence of its UI.
        let displays = spaces.readDisplays()
        guard let display = displays.first(where: { $0.uuid == screenUUID })
                ?? (displays.count == 1 ? displays.first : nil),
              display.spaces.contains(tile.layout.space) else { return false }
        return targets(in: tile.layout.space.id).contains { $0.pid == target.pid && $0.bundleID == target.bundleID && $0.windowIDs == target.windowIDs }
    }
    struct MappedList {
        let screen: ScreenRecord
        let display: SpaceReader.Display
        let buttons: [AXUIElement]
        let layout: [TileLayout]
    }
    // Display IDs are optional in Dock's AX tree. Rendering and cleanup MUST use
    // this same resolver, including the geometry fallback for an absent AXDisplayID.
    func mappedLists(screens: [ScreenRecord], lists: [SpaceList], expanded: Bool = true) -> [MappedList] {
        let displays = spaces.readDisplays()
        var result: [MappedList] = []
        for list in lists {
            let measured = LayoutRules.measureAndSort(list.buttons) { button -> CGRect? in
                let data = AX.attributes(button, [kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute])
                guard data[kAXRoleAttribute] as? String == kAXButtonRole,
                      let raw = AX.frame(data) else { return nil }
                return LayoutRules.spaceFrame(center: raw.origin, size: raw.size)
            }
            guard let first = measured.first?.frame else { continue }
            let ordered = measured.map(\.item)
            let frames = measured.map(\.frame)
            let screen = ScreenRecord.matching(screens, displayID: list.displayID,
                point: CGPoint(x: first.midX, y: first.midY))
            guard let screen, !result.contains(where: { $0.screen.id == screen.id }),
                  let display = displays.first(where: { $0.uuid == screen.uuid })
                    ?? (screens.count == 1 && displays.count == 1 ? displays.first : nil),
                  let layout = LayoutRules.map(spaces: display.spaces, frames: frames, screen: screen.frame, expanded: expanded) else { continue }
            result.append(MappedList(screen: screen, display: display, buttons: ordered, layout: layout))
        }
        return result
    }
    func snapshot(screens: [ScreenRecord]) -> Snapshot {
        guard AXIsProcessTrusted() else {
            return Snapshot(tiles: [], message: "Bedienungshilfen noch nicht erlaubt")
        }
        let lists = self.lists()
        guard !lists.isEmpty else {
            return Snapshot(tiles: [], message: "Bereit – Mission Control öffnen")
        }
        let mappedLists = self.mappedLists(screens: screens, lists: lists)
        let ids = Set(mappedLists.flatMap { $0.layout.filter { $0.space.type == 4 }.map { $0.space.id } })
        let now = ProcessInfo.processInfo.systemUptime
        if ids.isEmpty { targetCache.removeAll(); return Snapshot(tiles: [], message: "Leiste erkannt – keine aufgeklappte Vollbild-Kachel") }
        if Set(targetCache.keys) != ids || now - targetCacheTime >= 0.6 {
            let catalog = WindowCatalog(rows: CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            targetCache = Dictionary(uniqueKeysWithValues: ids.map { ($0, targets(in: $0, catalog: catalog)) })
            targetCacheTime = now
        }
        var tiles: [CloseTile] = []
        for mapped in mappedLists {
            for tile in mapped.layout where tile.space.type == 4 {
                let targets = targetCache[tile.space.id] ?? []
                if !targets.isEmpty { tiles.append(CloseTile(displayID: mapped.screen.id, layout: tile, targets: targets)) }
            }
        }
        return Snapshot(tiles: tiles,
            message: tiles.isEmpty ? "Leiste erkannt – keine zuordenbare Vollbild-App" : "\(tiles.count) Vollbild-Kachel(n) erkannt")
    }

    func closeWindow(target: AppTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == target.bundleID, !app.isTerminated else { return false }
        let root = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var candidates: [CGWindowID: AXUIElement] = [:]
        for window in AX.elements(root, kAXWindowsAttribute) {
            if let id = AX.windowID(window), target.windowIDs.contains(id) { candidates[id] = window }
        }
        guard candidates.count == 1, let window = candidates.values.first,
              let button = AX.element(window, kAXCloseButtonAttribute) else { return false }
        AXUIElementSetMessagingTimeout(button, 0.25)
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        // A modal close confirmation can outlive AX's response timeout. Observe
        // the actual result/dialog instead of treating that timeout as a refusal.
        return result == .success || result == .cannotComplete
    }
    func hasTargetWindow(_ target: AppTarget) -> Bool? {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return rows.contains { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let id = row[kCGWindowNumber as String] as? NSNumber else { return false }
            return pid.int32Value == target.pid && target.windowIDs.contains(id.uint32Value)
        }
    }
    enum CleanupResult { case gone, requested, protected, unavailable }
    func removeEmptyFullscreenSpace(_ tile: CloseTile, target: AppTarget, screens: [ScreenRecord]) -> CleanupResult {
        let displays = spaces.readDisplays()
        guard !displays.isEmpty else { return .unavailable }
        guard displays.contains(where: { $0.spaces.contains(tile.layout.space) }) else { return .gone }
        guard
              let ids = spaces.windowIDsResult(in: tile.layout.space.id),
              let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              !rows.isEmpty else { return .unavailable }
        let hasLiveApp = rows.contains { row in
            guard let id = row[kCGWindowNumber as String] as? NSNumber, ids.contains(id.uint32Value),
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value != getpid(),
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  CleanupRules.isContentWindow(layer: layer.intValue, width: frame.width, height: frame.height) else { return false }
            guard let app = NSRunningApplication(processIdentifier: pid.int32Value) else { return true }
            return app.activationPolicy != .prohibited && !app.isTerminated
        }
        guard CleanupRules.canRemoveSpace(type: tile.layout.space.type,
            targetWindowPresent: hasTargetWindow(target) != false, anotherAppPresent: hasLiveApp, readSucceeded: true)
            else { return .protected }
        guard let mapped = mappedLists(screens: screens, lists: lists(), expanded: false).first(where: { $0.screen.id == tile.displayID }),
              let index = mapped.display.spaces.firstIndex(of: tile.layout.space) else { return .unavailable }
        let button = mapped.buttons[index]
        var actions: CFArray?
        AXUIElementSetMessagingTimeout(button, 0.12)
        guard AXUIElementCopyActionNames(button, &actions) == .success,
              (actions as? [String])?.contains("AXRemoveDesktop") == true,
              hasTargetWindow(target) == false, targets(in: tile.layout.space.id).isEmpty else { return .unavailable }
        return AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString) == .success ? .requested : .unavailable
    }
}
