import Foundation
import CoreGraphics

struct SpaceRecord: Equatable {
    let id: UInt64
    let type: Int
}

struct TileLayout: Equatable {
    let space: SpaceRecord
    let frame: CGRect // Accessibility / Quartz coordinates: origin at top left.
    var closeFrame: CGRect {
        CGRect(x: frame.maxX - 32, y: frame.minY + 4, width: 28, height: 28)
    }
}

enum LayoutRules {
    // Measure each remote element once; sorting itself performs no AX calls.
    static func measureAndSort<Item>(_ items: [Item], measure: (Item) -> CGRect?) -> [(item: Item, frame: CGRect)] {
        items.compactMap { item in measure(item).map { (item: item, frame: $0) } }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
    // Mission Control's space buttons expose a center anchor as AXPosition on
    // the tested Dock implementation. Ordinary AX windows use a top-left origin.
    static func spaceFrame(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
               width: size.width, height: size.height)
    }
    // Do not guess a target when Mission Control is expanding, scrolling or changing order.
    static func map(spaces: [SpaceRecord], frames: [CGRect], screen: CGRect, expanded: Bool = true) -> [TileLayout]? {
        guard !spaces.isEmpty, spaces.count == frames.count,
              Set(spaces.map(\.id)).count == spaces.count,
              spaces.allSatisfy({ $0.id > 0 && [0, 4].contains($0.type) }) else { return nil }
        let ordered = frames.sorted { $0.minX < $1.minX }
        for (index, frame) in ordered.enumerated() {
            guard frame.width >= (expanded ? 45 : 1), frame.height >= (expanded ? 38 : 1),
                  frame.width.isFinite, frame.height.isFinite,
                  frame.minX.isFinite, frame.minY.isFinite,
                  screen.insetBy(dx: -2, dy: -2).contains(frame),
                  frame.minY < screen.minY + screen.height * 0.32 else { return nil }
            if index > 0 {
                let previous = ordered[index - 1]
                // Hovering can lift an individual Space preview vertically.
                guard frame.minX >= previous.maxX - 2 else { return nil }
            }
        }
        return zip(spaces, ordered).map { TileLayout(space: $0.0, frame: $0.1) }
    }

    static func cocoaFrame(_ quartz: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: primaryTop - quartz.maxY, width: quartz.width, height: quartz.height)
    }
}

// Decode the expensive window dictionaries once per catalog refresh, then use
// window-ID lookups for all Spaces instead of decoding every row for every Space.
struct WindowCatalog {
    private let windows: [CGWindowID: pid_t]
    init(rows: [[String: Any]]) {
        var indexed: [CGWindowID: pid_t] = [:]
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? NSNumber,
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 150, frame.height >= 100 else { continue }
            indexed[id.uint32Value] = pid.int32Value
        }
        windows = indexed
    }
    func owners(of ids: Set<CGWindowID>) -> [pid_t: Set<CGWindowID>] {
        var grouped: [pid_t: Set<CGWindowID>] = [:]
        for id in ids { if let pid = windows[id] { grouped[pid, default: []].insert(id) } }
        return grouped
    }
}

enum CleanupRules {
    static func isContentWindow(layer: Int, width: CGFloat, height: CGFloat) -> Bool {
        layer == 0 && width > 0 && height > 0
    }
    static func canRemoveSpace(type: Int?, targetWindowPresent: Bool,
        anotherAppPresent: Bool, readSucceeded: Bool) -> Bool {
        type == 4 && readSucceeded && !targetWindowPresent && !anotherAppPresent
    }
}

struct AppTarget: Equatable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let windowIDs: Set<CGWindowID>
}

struct CloseTile: Equatable {
    let displayID: CGDirectDisplayID
    let layout: TileLayout
    let targets: [AppTarget]
    var key: String { "\(displayID):\(layout.space.id)" }
}

// Alive does not imply a dialog. Only an observed, new modal/sheet can request focus.
struct CloseProgress {
    enum Decision: Equatable { case waiting, focus(UInt), finished, dialogDismissed, timedOut }
    private var focused: Set<UInt> = []
    private var dialogGoneAt: TimeInterval?
    var hasFocusedDialog: Bool { !focused.isEmpty }
    mutating func observe(pending: Bool, dialogs: [UInt], elapsed: TimeInterval) -> Decision {
        if !pending { return .finished }
        if elapsed >= 90 { return .timedOut }
        if hasFocusedDialog && dialogs.isEmpty {
            if let since = dialogGoneAt, elapsed - since >= 1 { return .dialogDismissed }
            if dialogGoneAt == nil { dialogGoneAt = elapsed }
        } else { dialogGoneAt = nil }
        if let id = dialogs.first(where: { !focused.contains($0) }) {
            focused.insert(id)
            return .focus(id)
        }
        return .waiting
    }
}

enum DialogRules {
    static func isBlocking(role: String, modal: Bool?, subrole: String = "", focused: Bool = false) -> Bool {
        if role == "AXSheet" { return true }
        if modal == true { return role == "AXWindow" || subrole == "AXDialog" || subrole == "AXSystemDialog" }
        if modal == false { return false }
        // Missing modality alone is insufficient. A focused semantic dialog is
        // accepted, but an ordinary focused document window never is.
        return focused && (role == "AXDialog" || subrole == "AXDialog" || subrole == "AXSystemDialog")
    }
}

// A press owns its release even if Mission Control disappears meanwhile. Actions
// only fire after a complete click on the same control, never during a drag.
enum MouseButton: Hashable { case primary, secondary }
struct ClickIntent: Equatable {
    let tile: CloseTile
    let contextMenu: Bool
    let point: CGPoint
}
struct ReleaseResult {
    let consumed: Bool
    let intent: ClickIntent?
}
final class ClickRouter {
    private struct Press {
        let tile: CloseTile
        let contextMenu: Bool
        let origin: CGPoint
        let hit: CGRect
        let tileHit: Bool
        var dragged = false
    }
    private var presses: [MouseButton: Press] = [:]
    func down(button: MouseButton, contextMenu: Bool, point: CGPoint, tiles: [CloseTile], buttonFrames: [String: CGRect] = [:], requestMenu: Bool? = nil) -> Bool {
        presses.removeValue(forKey: button)
        guard let tile = tiles.first(where: {
            (contextMenu ? $0.layout.frame : (buttonFrames[$0.key] ?? $0.layout.closeFrame)).contains(point)
        }) else { return false }
        presses[button] = Press(tile: tile, contextMenu: requestMenu ?? contextMenu, origin: point,
            hit: contextMenu ? tile.layout.frame : (buttonFrames[tile.key] ?? tile.layout.closeFrame), tileHit: contextMenu)
        return true
    }
    @discardableResult
    func drag(button: MouseButton, point: CGPoint) -> Bool {
        guard var press = presses[button] else { return false }
        if hypot(point.x - press.origin.x, point.y - press.origin.y) > 6 { press.dragged = true }
        presses[button] = press
        return true
    }
    func up(button: MouseButton, point: CGPoint, tiles: [CloseTile], buttonFrames: [String: CGRect] = [:]) -> ReleaseResult {
        guard let press = presses.removeValue(forKey: button) else {
            return ReleaseResult(consumed: false, intent: nil)
        }
        let distance = hypot(point.x - press.origin.x, point.y - press.origin.y)
        guard !press.dragged, distance <= 6, press.hit.contains(point),
              let tile = tiles.first(where: { $0.key == press.tile.key && $0.targets == press.tile.targets }),
              (press.tileHit ? tile.layout.frame : (buttonFrames[tile.key] ?? tile.layout.closeFrame)).contains(point) else {
            return ReleaseResult(consumed: true, intent: nil)
        }
        return ReleaseResult(consumed: true,
            intent: ClickIntent(tile: tile, contextMenu: press.contextMenu, point: point))
    }
}
