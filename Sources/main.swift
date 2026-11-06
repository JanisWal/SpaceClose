import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

final class CloseMark: NSView {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor.white.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.8
        cross.lineCapStyle = .round
        let left = bounds.midX - 4.2, right = bounds.midX + 4.2
        let bottom = bounds.midY - 4.2, top = bounds.midY + 4.2
        cross.move(to: NSPoint(x: left, y: bottom)); cross.line(to: NSPoint(x: right, y: top))
        cross.move(to: NSPoint(x: left, y: top)); cross.line(to: NSPoint(x: right, y: bottom))
        cross.stroke()
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class Overlay {
    let panel: NSPanel
    let spaces: SpaceReader
    private var previewReady = false
    private var label = ""
    let mark = CloseMark(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    init(spaces: SpaceReader) {
        self.spaces = spaces
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenNone]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        panel.contentView = mark
        mark.setAccessibilityElement(true)
        mark.setAccessibilityRole(.button)
        _ = spaces.excludeOwnOverlayFromPreviews(windowID: CGWindowID(panel.windowNumber))
    }
    func show(_ tile: CloseTile, primaryTop: CGFloat, behavior: CloseBehavior) -> Bool {
        let frame = LayoutRules.cocoaFrame(tile.layout.closeFrame, primaryTop: primaryTop)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
        // WindowServer commits the tags asynchronously. Do not show/click a new
        // panel until a later run-loop pass can read back the exclusion flags.
        if !previewReady {
            previewReady = spaces.ownOverlayIsExcluded(windowID: CGWindowID(panel.windowNumber))
            if !previewReady {
                panel.orderOut(nil)
                _ = spaces.excludeOwnOverlayFromPreviews(windowID: CGWindowID(panel.windowNumber))
                return false
            }
        }
        let title = tile.targets.count == 1 ? "\(tile.targets[0].name): \(behavior.title)" : "App zum Schließen auswählen"
        if label != title {
            label = title
            mark.toolTip = title
            mark.setAccessibilityLabel(title)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        return true
    }
}

final class TargetAction: NSObject {
    let tile: CloseTile
    let app: AppTarget
    let windowOnly: Bool
    init(tile: CloseTile, app: AppTarget, windowOnly: Bool) {
        self.tile = tile; self.app = app; self.windowOnly = windowOnly
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let reader = MissionReader()
    let closingReader = MissionReader()
    let layoutWorker = DispatchQueue(label: "local.spaceclose.layout", qos: .userInitiated)
    let worker = DispatchQueue(label: "local.spaceclose.reader", qos: .userInitiated)
    let clicks = ClickRouter()
    let preferences = Preferences()
    let permissionProbe = FreshPermissionProbe()
    var lastPermissionProbe: TimeInterval = -10
    var restarting = false
    var interactionEpoch: UInt64 = 0
    var closeJobs: [pid_t: UUID] = [:]
    let didPermissionRestart = CommandLine.arguments.contains("--permission-restarted")
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var startItem: NSMenuItem!
    var pauseItem: NSMenuItem!
    var timer: Timer?
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var overlays: [String: Overlay] = [:]
    var current: [CloseTile] = []
    var reading = false
    var lastRead: TimeInterval = 0
    var lastSnapshotTime: TimeInterval = 0
    var enabled: Bool { preferences.enabled }
    var actionInFlight = false
    var menuVisible = false
    var refreshEpoch: UInt64 = 0
    var suppressUntil: TimeInterval = 0
    var permissionWindow: NSWindow?
    var lastTapAttempt: TimeInterval = -10
    var isTrusted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(preferences.showDock ? .regular : .accessory)
        makeStatusMenu()
        configurePreferences()
        statusItem.isVisible = preferences.showMenuBar
        isTrusted = AXIsProcessTrusted()
        preferences.trusted = isTrusted
        if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") || !isTrusted
            || CommandLine.arguments.contains("--show-settings") { showSetup(nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(returnedToApp),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        permissionProbe.cancel()
        hide()
        removeTap()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup(nil)
        return true
    }
    @objc func screenChanged() {
        refreshEpoch &+= 1
        hide()
        layoutWorker.async { self.reader.invalidateLayoutCache() }
        worker.async { self.closingReader.invalidateLayoutCache() }
        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.45
    }
    func makeStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "SpaceClose")
            ?? NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "SpaceClose")
        statusItem.button?.toolTip = "SpaceClose – Vollbild-Apps in Mission Control beenden"
        let menu = NSMenu()
        menu.addItem(withTitle: "SpaceClose", action: nil, keyEquivalent: "")
        statusLine = menu.addItem(withTitle: "Wird gestartet …", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let explanation = menu.addItem(withTitle: "X: \(preferences.closeBehavior.title)", action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        pauseItem = menu.addItem(withTitle: "Aktiv", action: #selector(toggleEnabled), keyEquivalent: "")
        pauseItem.state = .on
        startItem = menu.addItem(withTitle: "Beim Anmelden starten", action: #selector(toggleLogin), keyEquivalent: "")
        startItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Einstellungen …", action: #selector(showSetup), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "SpaceClose beenden", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        let main = NSMenu()
        let appMenu = NSMenu(title: "SpaceClose")
        let appItem = NSMenuItem(title: "SpaceClose", action: nil, keyEquivalent: "")
        main.addItem(appItem); main.setSubmenu(appMenu, for: appItem)
        let settings = appMenu.addItem(withTitle: "Einstellungen …", action: #selector(showSetup), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "SpaceClose beenden", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        let windowMenu = NSMenu(title: "Fenster")
        let windowItem = NSMenuItem(title: "Fenster", action: nil, keyEquivalent: "")
        main.addItem(windowItem); main.setSubmenu(windowMenu, for: windowItem)
        windowMenu.addItem(withTitle: "Fenster schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
    func configurePreferences() {
        preferences.onEnabled = { [weak self] value in
            guard let self else { return }
            self.pauseItem.state = value ? .on : .off
            self.refreshEpoch &+= 1
            self.hide()
            if !value { self.setStatus("Pausiert") }
        }
        preferences.onMenuBar = { [weak self] value in self?.statusItem.isVisible = value }
        preferences.onDock = { value in NSApp.setActivationPolicy(value ? .regular : .accessory) }
        preferences.onLogin = { [weak self] value in self?.setLogin(value) }
        preferences.onAccessibility = { [weak self] in self?.openAccessibility() }
        preferences.onRecheckPermission = { [weak self] in self?.refreshPermission(manual: true) }
        preferences.onRestart = { [weak self] in self?.restartForPermission() }
        preferences.onQuit = { [weak self] in self?.quit() }
        pauseItem.state = enabled ? .on : .off
    }
    func setStatus(_ message: String) {
        if statusLine.title != message { statusLine.title = message }
        if preferences.status != message { preferences.status = message }
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleEnabled() {
        preferences.enabled.toggle()
    }
    @objc func toggleLogin() {
        setLogin(SMAppService.mainApp.status != .enabled)
    }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
            preferences.loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Bitte SpaceClose noch in den macOS-Anmeldeobjekten erlauben." : ""
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
            preferences.loginMessage = "Autostart konnte nicht geändert werden. Bitte SpaceClose zuerst in Programme installieren."
        }
    }

    func installTap() {
        guard tap == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTapAttempt > 5 else { return }
        lastTapAttempt = now
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged, .rightMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.hide()
                if type == .tapDisabledByTimeout, AXIsProcessTrusted(), owner.enabled {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    DispatchQueue.main.async { owner.removeTap() }
                }
                return Unmanaged.passUnretained(event)
            }
            return owner.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        tap = nil
        lastTapAttempt = -10
    }
    @objc func returnedToApp() { refreshPermission(manual: false) }
    func refreshPermission(manual: Bool) {
        guard !restarting, !permissionProbe.running else { return }
        let localTrusted = AXIsProcessTrusted()
        if localTrusted {
            isTrusted = true
            preferences.trusted = true
            preferences.permissionMessage = ""
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard manual || now - lastPermissionProbe > 3 else { return }
        guard let executable = Bundle.main.executableURL else { return }
        lastPermissionProbe = now
        if manual { preferences.checkingPermission = true }
        permissionProbe.run(executable: executable) { [weak self] result in
            guard let self, !self.restarting else { return }
            self.preferences.checkingPermission = false
            switch PermissionRecovery.decide(localTrusted: AXIsProcessTrusted(),
                freshExitCode: result, didRestart: self.didPermissionRestart) {
            case .ready:
                self.isTrusted = true
                self.preferences.trusted = true
                self.preferences.permissionMessage = ""
            case .restartNeeded:
                self.preferences.permissionMessage = "Freigabe gespeichert. SpaceClose startet neu, um sie zu übernehmen."
                self.restartForPermission()
            case .restartAlreadyTried:
                self.preferences.permissionMessage = "Die neue Prüfung sieht die Freigabe, diese Instanz noch nicht. Starte SpaceClose über die Schaltfläche unten erneut."
            case .grantNeeded:
                let message = "macOS meldet noch keine Freigabe für diese App-Kopie. Falls der Schalter schon an ist: den alten SpaceClose-Eintrag mit − entfernen und die installierte App aus Programme mit + neu hinzufügen."
                if self.preferences.permissionMessage != message { self.preferences.permissionMessage = message }
            case .checkFailed:
                self.preferences.permissionMessage = "Die frische Prüfung war nicht möglich. Du kannst SpaceClose unten neu starten; eine Freigabe wurde nicht verändert."
            }
        }
    }
    func restartForPermission() {
        guard !restarting else { return }
        restarting = true
        refreshEpoch &+= 1
        hide()
        removeTap()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.arguments = ["--permission-restarted", "--show-settings"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, let app, app.processIdentifier != getpid() else {
                    self.restarting = false
                    self.preferences.permissionMessage = "Neustart nicht möglich. Bitte SpaceClose vollständig beenden und die installierte App neu öffnen."
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    func tick() {
        guard !restarting else { return }
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            preferences.trusted = trusted
            if !trusted { refreshEpoch &+= 1; hide(); removeTap() }
            else { preferences.permissionMessage = "" }
        }
        guard trusted else {
            setStatus("Bedienungshilfen noch nicht übernommen")
            refreshPermission(manual: false)
            return
        }
        guard enabled, !actionInFlight else { return }
        installTap()
        guard tap != nil else {
            setStatus("Mauszugriff fehlt – Einstellungen öffnen")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= suppressUntil else { return }
        let interval: TimeInterval = current.isEmpty ? 0.2 : 0.12
        guard !reading, now - lastRead >= interval, !menuVisible else { return }
        lastRead = now
        reading = true
        let screens = ScreenRecord.capture()
        let epoch = refreshEpoch
        layoutWorker.async { [weak self] in
            guard let self else { return }
            let snapshot = self.reader.snapshot(screens: screens)
            DispatchQueue.main.async {
                self.reading = false
                guard epoch == self.refreshEpoch else { return }
                self.setStatus(snapshot.message)
                guard self.enabled, self.isTrusted, !self.actionInFlight,
                      ProcessInfo.processInfo.systemUptime >= self.suppressUntil else { self.hide(); return }
                self.lastSnapshotTime = ProcessInfo.processInfo.systemUptime
                self.render(snapshot.tiles)
            }
        }
    }
    func render(_ tiles: [CloseTile]) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let liveKeys = Set(tiles.map(\.key))
        for key in Array(overlays.keys) where !liveKeys.contains(key) {
            overlays.removeValue(forKey: key)?.panel.close()
        }
        current = tiles
        for tile in tiles {
            let overlay = overlays[tile.key] ?? Overlay(spaces: reader.spaces)
            overlays[tile.key] = overlay
            _ = overlay.show(tile, primaryTop: top, behavior: preferences.closeBehavior)
            overlay.mark.onPress = { [weak self] in
                guard let self, self.enabled, !self.actionInFlight else { return }
                if tile.targets.count == 1 {
                    self.perform(tile: tile, target: tile.targets[0], windowOnly: self.preferences.closeBehavior == .closeWindow)
                } else { self.showActions(tile, at: CGPoint(x: tile.layout.frame.midX, y: tile.layout.frame.midY)) }
            }
        }
    }
    func hide() {
        current = []
        for overlay in overlays.values { overlay.panel.close() }
        overlays.removeAll()
    }
    // One input path: the session event tap owns down and up over each visible X.
    // A stale visible button still consumes its click; the worker revalidates its
    // process/Space/window identity before sending any close request.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .leftMouseDragged || type == .rightMouseDragged {
            return clicks.drag(button: type == .leftMouseDragged ? .primary : .secondary, point: event.location)
        }
        let visible = current.filter { overlays[$0.key]?.panel.isVisible == true }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frames = overlays.filter { $0.value.panel.isVisible }
            .mapValues { LayoutRules.cocoaFrame($0.panel.frame, primaryTop: top) }
        if type == .leftMouseUp || type == .rightMouseUp {
            let result = clicks.up(button: type == .leftMouseUp ? .primary : .secondary,
                point: event.location, tiles: visible, buttonFrames: frames)
            if let intent = result.intent {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled, !self.actionInFlight, !self.menuVisible else { return }
                    if intent.contextMenu || intent.tile.targets.count != 1 {
                        self.showActions(intent.tile, at: intent.point)
                    } else {
                        self.perform(tile: intent.tile, target: intent.tile.targets[0],
                            windowOnly: self.preferences.closeBehavior == .closeWindow)
                    }
                }
            }
            return result.consumed
        }
        guard type == .leftMouseDown || type == .rightMouseDown else { return false }
        let overX = frames.values.contains { $0.contains(event.location) }
        if !overX { interactionEpoch &+= 1 }
        guard enabled, !menuVisible, !actionInFlight else { return false }
        let context = type == .rightMouseDown || event.flags.contains(.maskControl)
        // Body context menus require recent geometry. X clicks use the visible
        // window's exact frame and are always validated again before acting.
        let allowBodyMenu = context && ProcessInfo.processInfo.systemUptime - lastSnapshotTime < 0.8
        guard overX || allowBodyMenu else { return false }
        return clicks.down(button: type == .leftMouseDown ? .primary : .secondary,
            contextMenu: context && !overX, point: event.location, tiles: visible, buttonFrames: frames,
            requestMenu: context)
    }
    func showActions(_ tile: CloseTile, at point: CGPoint) {
        let menu = NSMenu()
        menu.delegate = self
        let label = menu.addItem(withTitle: "Vollbild-App", action: nil, keyEquivalent: "")
        label.isEnabled = false
        for app in tile.targets {
            let quit = NSMenuItem(title: "\(app.name) beenden (alle Fenster)", action: #selector(menuAction), keyEquivalent: "")
            quit.target = self
            quit.representedObject = TargetAction(tile: tile, app: app, windowOnly: false)
            menu.addItem(quit)
            let close = NSMenuItem(title: "Nur Vollbildfenster von \(app.name) schließen", action: #selector(menuAction), keyEquivalent: "")
            close.target = self
            close.representedObject = TargetAction(tile: tile, app: app, windowOnly: true)
            menu.addItem(close)
        }
        menu.addItem(.separator())
        let cancel = menu.addItem(withTitle: "Abbrechen", action: #selector(cancelMenu), keyEquivalent: "")
        cancel.target = self
        menuVisible = true
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: top - point.y), in: nil)
        menuVisible = false

        hide()
    }
    func menuWillOpen(_ menu: NSMenu) { menuVisible = true }
    func menuDidClose(_ menu: NSMenu) { menuVisible = false }
    @objc func cancelMenu() {}
    @objc func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? TargetAction else { return }
        perform(tile: action.tile, target: action.app, windowOnly: action.windowOnly)
    }
    func perform(tile: CloseTile, target: AppTarget, windowOnly: Bool) {
        guard !actionInFlight, closeJobs[target.pid] == nil else { return }
        actionInFlight = true
        refreshEpoch &+= 1
        hide()
        setActionStatus("Schließanfrage für \(target.name) wird gesendet …")
        let screenUUID = ScreenRecord.capture().first(where: { $0.id == tile.displayID })?.uuid
        let inputEpoch = interactionEpoch
        worker.async { [weak self] in
            guard let self else { return }
            guard self.closingReader.isCurrentTarget(target, tile: tile, screenUUID: screenUUID) else {
                DispatchQueue.main.async {
                    self.actionInFlight = false
                    self.setActionStatus("Kachel hat sich geändert – bitte erneut wählen.")
                }
                return
            }
            // Prevent generating a dead thumbnail: leave overview BEFORE asking
            // the app to close. Failure to leave overview must never block Quit.
            let didHide = !self.closingReader.lists().isEmpty && self.closingReader.spaces.toggleMissionControl()
            self.worker.asyncAfter(deadline: .now() + (didHide ? 0.3 : 0)) {
                let overviewClosed = didHide && self.closingReader.lists().isEmpty
                let windowAccepted = windowOnly && self.closingReader.closeWindow(target: target)
                DispatchQueue.main.async {
                    self.actionInFlight = false
                    guard let app = NSRunningApplication(processIdentifier: target.pid),
                          app.bundleIdentifier == target.bundleID, !app.isTerminated else {
                        self.setActionStatus("Die App ist bereits beendet.")
                        self.finishClose(tile: tile, target: target, restore: overviewClosed, inputEpoch: inputEpoch)
                        return
                    }
                    let accepted = windowOnly ? windowAccepted : app.terminate()
                    guard accepted else {
                        self.setActionStatus("Die App hat die Schließanfrage nicht angenommen.")
                        self.returnToOverview(allowed: overviewClosed, inputEpoch: inputEpoch)
                        return
                    }
                    let token = UUID()
                    self.closeJobs[target.pid] = token
                    self.monitorClose(tile: tile, target: target, wholeApp: !windowOnly,
                        token: token, progress: CloseProgress(),
                        started: ProcessInfo.processInfo.systemUptime,
                        restore: overviewClosed, inputEpoch: inputEpoch)
                }
            }
        }
    }
    func monitorClose(tile: CloseTile, target: AppTarget, wholeApp: Bool,
        token: UUID, progress: CloseProgress, started: TimeInterval,
        restore: Bool, inputEpoch: UInt64) {
        worker.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let app = NSRunningApplication(processIdentifier: target.pid)
            let running = app?.bundleIdentifier == target.bundleID && app?.isTerminated == false
            let pending = running && (wholeApp || self.closingReader.hasTargetWindow(target) != false)
            let dialogs = pending ? self.closingReader.dialogs(for: target, wholeApp: wholeApp) : []
            DispatchQueue.main.async {
                guard self.closeJobs[target.pid] == token else { return }
                var next = progress
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                switch next.observe(pending: pending, dialogs: dialogs.map(\.id), elapsed: elapsed) {
                case .finished:
                    self.closeJobs.removeValue(forKey: target.pid)
                    self.setActionStatus(wholeApp ? "\(target.name) wurde beendet." : "Das Vollbildfenster wurde geschlossen.")
                    self.finishClose(tile: tile, target: target,
                        restore: restore && elapsed < 3, inputEpoch: inputEpoch)
                    return
                case .dialogDismissed:
                    self.closeJobs.removeValue(forKey: target.pid)
                    self.setActionStatus("Die Rückfrage ist geschlossen; die App ist weiterhin offen.")
                    return
                case .timedOut:
                    self.closeJobs.removeValue(forKey: target.pid)
                    self.setActionStatus("Die App ist weiterhin offen. Es wurde kein Beenden erzwungen.")
                    return
                case .focus(let id):
                    if let dialog = dialogs.first(where: { $0.id == id }) {
                        self.setActionStatus("Rückfrage von \(target.name) erkannt – bitte beantworten.")
                        self.focusDialog(dialog, target: target, token: token, inputEpoch: self.interactionEpoch)
                    }
                case .waiting: break
                }
                self.monitorClose(tile: tile, target: target, wholeApp: wholeApp,
                    token: token, progress: next, started: started,
                    restore: restore && !next.hasFocusedDialog, inputEpoch: inputEpoch)
            }
        }
    }
    func focusDialog(_ dialog: BlockingDialog, target: AppTarget, token: UUID, inputEpoch: UInt64, attempt: Int = 0) {
        worker.async { [weak self] in
            guard let self, self.closingReader.dialogIsPresent(dialog, target: target) else { return }
            DispatchQueue.main.async {
                guard self.closeJobs[target.pid] == token,
                      let app = NSRunningApplication(processIdentifier: target.pid),
                      app.bundleIdentifier == target.bundleID, !app.isTerminated else { return }
                let activated = app.activate(options: [.activateIgnoringOtherApps])
                self.worker.asyncAfter(deadline: .now() + 0.08) { self.closingReader.raiseDialog(dialog, target: target) }
                if !activated && attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard inputEpoch == self.interactionEpoch else { return }
                        self.focusDialog(dialog, target: target, token: token, inputEpoch: inputEpoch, attempt: attempt + 1)
                    }
                }
            }
        }
    }
    func setActionStatus(_ message: String) {
        preferences.actionMessage = message
        setStatus(message)
    }
    func returnToOverview(allowed: Bool, inputEpoch: UInt64) {
        guard allowed, inputEpoch == interactionEpoch else { return }
        worker.async { [weak self] in
            guard let self, self.closingReader.lists().isEmpty else { return }
            DispatchQueue.main.async {
                guard inputEpoch == self.interactionEpoch else { return }
                _ = self.closingReader.spaces.toggleMissionControl()
            }
        }
    }
    func finishClose(tile: CloseTile, target: AppTarget, restore: Bool, inputEpoch: UInt64) {
        returnToOverview(allowed: restore, inputEpoch: inputEpoch)
        let screens = ScreenRecord.capture()
        // Separate recovery: cleanup can never suppress the close request. No
        // system process restart and no removal based on a stale thumbnail alone.
        worker.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let result = self.closingReader.removeEmptyFullscreenSpace(tile, target: target, screens: screens)
            if result == .requested {
                self.worker.asyncAfter(deadline: .now() + 0.35) {
                    let remaining = self.closingReader.spaces.readDisplays().contains { $0.spaces.contains(tile.layout.space) }
                    if remaining { DispatchQueue.main.async {
                        self.setActionStatus("App geschlossen; der leere Vollbildbereich konnte noch nicht entfernt werden.")
                    } }
                }
            } else if result == .unavailable {
                let remaining = self.closingReader.spaces.readDisplays().contains { $0.spaces.contains(tile.layout.space) }
                if remaining { DispatchQueue.main.async {
                    self.setActionStatus("App geschlossen; Bereinigung der Vollbild-Kachel noch nicht bestätigt.")
                } }
            }
        }
    }

    @objc func showSetup(_ sender: Any?) {
        if let permissionWindow {
            permissionWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SpaceClose-Einstellungen"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 660)
        window.setFrameAutosaveName("SpaceCloseSettings")
        window.center()
        window.contentViewController = NSHostingController(rootView: SettingsView(preferences: preferences))
        window.setContentSize(NSSize(width: 560, height: 700))
        permissionWindow = window
        UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func openAccessibility() {
        // Opening the asynchronous prompt and Settings together could leave the
        // permission alert blocking the switch the user needs to activate.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

}

if let index = CommandLine.arguments.firstIndex(of: "--render-settings"), CommandLine.arguments.count > index + 1 {
    renderSettingsPreview(path: CommandLine.arguments[index + 1], dark: CommandLine.arguments.contains("--dark"))
} else if CommandLine.arguments.contains("--permission-status") {
    exit(AXIsProcessTrusted() ? 0 : 3)
} else if CommandLine.arguments.contains("--diagnose-layout") {
    runLayoutDiagnostics()
} else if CommandLine.arguments.contains("--test-overlay-configuration") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let spaces = SpaceReader()
    var passed = true
    for cycle in 1...3 {
        var windowID: CGWindowID = 0
        autoreleasepool {
            let overlay = Overlay(spaces: spaces)
            windowID = CGWindowID(overlay.panel.windowNumber)
            overlay.panel.setFrame(NSRect(x: 100 + cycle * 20, y: 100, width: 28, height: 28), display: false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let excluded = spaces.ownOverlayIsExcluded(windowID: windowID)
            let independent = !overlay.panel.collectionBehavior.contains(.canJoinAllSpaces)
                && !overlay.panel.collectionBehavior.contains(.canJoinAllApplications)
                && !overlay.panel.collectionBehavior.contains(.fullScreenAuxiliary)
            passed = passed && excluded && independent && !overlay.panel.isVisible && overlay.panel.ignoresMouseEvents
            overlay.panel.close()
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
        let removed = rows.map { !$0.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID } } ?? false
        passed = passed && removed
        print("Unsichtbarer Overlay-Zyklus \(cycle): Fenster nach Freigabe entfernt: \(removed ? "ja" : "nein")")
    }
    print("Vorschauschutz, unabhängige Fenster und vollständiger Abbau: \(passed ? "bestanden" : "fehlgeschlagen")")
    exit(passed ? 0 : 1)
} else if CommandLine.arguments.contains("--test-permission-probe") {
    let probe = FreshPermissionProbe()
    var finished = false
    var code: Int32?
    probe.run(executable: Bundle.main.executableURL!) { result in code = result; finished = true }
    while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    if code == 0 || code == 3 {
        print("Frische Prozessprüfung abgeschlossen: \(code == 0 ? "erlaubt" : "nicht erlaubt").")
    } else { fputs("Frische Prozessprüfung fehlgeschlagen.\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else if CommandLine.arguments.contains("--benchmark-catalog") {
    runCatalogBenchmark()
} else if CommandLine.arguments.contains("--system-check") {
    let reader = SpaceReader()
    let displays = reader.readDisplays()
    let counts = displays.map { $0.spaces.count }
    let fullscreens = displays.flatMap(\.spaces).filter { $0.type == 4 }
    let membershipCounts = fullscreens.map { reader.windowIDs(in: $0.id).count }
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Space-Schnittstelle: \(reader.available ? "verfügbar" : "nicht verfügbar")")
    print("Übersicht neu anzeigen: \(reader.refreshAvailable ? "verfügbar" : "nicht verfügbar")")
    print("Overlay-Tags: \(reader.overlayTaggingAvailable ? "verfügbar" : "nicht verfügbar")")
    print("Displays: \(displays.count); Spaces je Display: \(counts)")
    print("Vollbild-Spaces: \(fullscreens.count); Fensterzahlen: \(membershipCounts)")
    print("Bedienungshilfen für diesen Prozess: \(AXIsProcessTrusted() ? "erlaubt" : "noch nicht erlaubt")")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
