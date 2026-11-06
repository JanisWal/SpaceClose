import Foundation
import CoreGraphics

func runSelfTests() {
    var passed = 0
    func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FEHLER: \(name)\n", stderr); exit(1) }
        passed += 1
    }
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let desktop = SpaceRecord(id: 1, type: 0)
    let fullscreen = SpaceRecord(id: 7, type: 4)
    let a = CGRect(x: 200, y: 40, width: 140, height: 90)
    let b = CGRect(x: 360, y: 40, width: 140, height: 90)
    let map = LayoutRules.map(spaces: [desktop, fullscreen], frames: [b, a], screen: screen)
    check(map?.map(\.space.id) == [1, 7], "Zuordnung nach tatsächlicher Leistenreihenfolge")
    check(map?[1].frame == b, "Vollbild-Kachel korrekt")
    check(map?[1].closeFrame == CGRect(x: 468, y: 44, width: 28, height: 28), "Größeres X innerhalb der rechten oberen Ecke")
    check(map?[1].frame.contains(map![1].closeFrame) == true, "X trifft ausschließlich seine Kachel")
    check(LayoutRules.map(spaces: [desktop], frames: [a, b], screen: screen) == nil, "Anzahlabweichung blockiert")
    check(LayoutRules.map(spaces: [desktop, desktop], frames: [a, b], screen: screen) == nil, "Doppelte IDs blockiert")
    check(LayoutRules.map(spaces: [SpaceRecord(id: 0, type: 4)], frames: [a], screen: screen) == nil, "Ungültige ID blockiert")
    check(LayoutRules.map(spaces: [SpaceRecord(id: 8, type: 99)], frames: [a], screen: screen) == nil, "Unbekannter Space-Typ blockiert")
    check(LayoutRules.map(spaces: [desktop], frames: [CGRect(x: 20, y: 5, width: 40, height: 20)], screen: screen) == nil, "Eingeklappte Leiste blockiert")
    check(LayoutRules.map(spaces: [desktop], frames: [CGRect(x: 20, y: 5, width: 40, height: 20)], screen: screen,
        expanded: false) != nil, "Native Bereinigung braucht keine aufgeklappten Vorschaubilder")
    check(LayoutRules.map(spaces: [desktop], frames: [CGRect(x: 20, y: 400, width: 140, height: 90)], screen: screen) == nil, "Fenster außerhalb der oberen Leiste blockiert")
    check(LayoutRules.map(spaces: [desktop, fullscreen], frames: [a, a], screen: screen) == nil, "Überlappende Animation blockiert")
    check(LayoutRules.map(spaces: [desktop], frames: [CGRect(x: -50, y: 40, width: 140, height: 90)], screen: screen) == nil, "Teilweise unsichtbare Kachel blockiert")
    let second = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
    let secondTile = CGRect(x: -1700, y: -160, width: 160, height: 100)
    check(LayoutRules.map(spaces: [fullscreen], frames: [secondTile], screen: second)?.count == 1, "Zweiter Bildschirm mit negativem Ursprung")
    check(LayoutRules.cocoaFrame(a, primaryTop: 900) == CGRect(x: 200, y: 770, width: 140, height: 90), "Quartz zu AppKit")
    check(LayoutRules.cocoaFrame(LayoutRules.cocoaFrame(secondTile, primaryTop: 900), primaryTop: 900) == secondTile, "Koordinatenumrechnung umkehrbar")
    let target = AppTarget(pid: 123, bundleID: "test.app", name: "Test", windowIDs: [42])
    let tile = CloseTile(displayID: 1, layout: map![1], targets: [target])
    let lifted = CGRect(x: b.minX, y: b.minY - 12, width: b.width, height: b.height)
    check(LayoutRules.map(spaces: [desktop, fullscreen], frames: [a, lifted], screen: screen) != nil,
        "Angehobene Hover-Kachel bleibt zuordenbar")
    let slight = CloseTile(displayID: tile.displayID,
        layout: TileLayout(space: fullscreen, frame: b.offsetBy(dx: 0.4, dy: -0.4)), targets: [target])
    let router = ClickRouter()
    let x = CGPoint(x: 485, y: 55)
    check(router.down(button: .primary, contextMenu: false, point: x, tiles: [tile]), "Drücken auf X abgefangen")
    let release = router.up(button: .primary, point: x, tiles: [tile])
    check(release.consumed && release.intent?.tile == tile, "Erst Loslassen löst X aus")
    check(!router.up(button: .primary, point: x, tiles: [tile]).consumed, "Fremdes Loslassen unverändert")
    let body = CGPoint(x: 410, y: 80)
    check(!router.down(button: .primary, contextMenu: false, point: body, tiles: [tile]), "Normaler Kachelklick bleibt macOS überlassen")
    check(router.down(button: .secondary, contextMenu: true, point: body, tiles: [tile]), "Rechtsklick auf Kachel erkannt")
    check(router.up(button: .secondary, point: body, tiles: [tile]).intent?.contextMenu == true, "Menü erst nach komplettem Rechtsklick")
    check(router.down(button: .primary, contextMenu: true, point: body, tiles: [tile]), "Control-Klick als Kontextmenü")
    check(router.up(button: .primary, point: body, tiles: [tile]).intent?.contextMenu == true, "Control-Klick-Menü korrekt")
    _ = router.down(button: .primary, contextMenu: false, point: x, tiles: [tile])
    let drag = router.up(button: .primary, point: CGPoint(x: 600, y: 200), tiles: [tile])
    check(drag.consumed && drag.intent == nil, "Wegziehen schließt keine App")
    _ = router.down(button: .primary, contextMenu: false, point: x, tiles: [tile])
    let gone = router.up(button: .primary, point: x, tiles: [])
    check(gone.consumed && gone.intent == nil, "Verschwundene Kachel schließt keine App")
    let realFrame = CGRect(x: 600, y: 45, width: 20, height: 20)
    let realPoint = CGPoint(x: 610, y: 55)
    check(router.down(button: .primary, contextMenu: false, point: realPoint, tiles: [tile],
        buttonFrames: [tile.key: realFrame]), "Trefferbereich folgt tatsächlich gezeichnetem X")
    check(router.up(button: .primary, point: realPoint, tiles: [tile], buttonFrames: [tile.key: realFrame]).intent != nil,
        "Auch versetztes Panel bleibt anklickbar")
    _ = router.down(button: .primary, contextMenu: false, point: x, tiles: [tile])
    check(router.up(button: .primary, point: x, tiles: [slight]).intent != nil,
        "Subpixel-Messung zwischen Drücken und Loslassen verwirft Klick nicht")
    _ = router.down(button: .primary, contextMenu: false, point: x, tiles: [tile])
    router.drag(button: .primary, point: body)
    let returned = router.up(button: .primary, point: x, tiles: [tile])
    check(returned.consumed && returned.intent == nil, "Wegziehen und Zurückkehren löst keinen Schließvorgang aus")
    _ = router.down(button: .primary, contextMenu: false, point: x, tiles: [tile])
    let replacement = CloseTile(displayID: tile.displayID, layout: tile.layout,
        targets: [AppTarget(pid: 456, bundleID: "other.app", name: "Andere", windowIDs: [45])])
    check(router.up(button: .primary, point: x, tiles: [replacement]).intent == nil,
        "Ausgetauschte App zwischen Drücken und Loslassen wird geschützt")
    check(PermissionRecovery.decide(localTrusted: true, freshExitCode: 3, didRestart: false) == .ready,
        "Echte lokale Freigabe hat Vorrang vor älterem Prüfergebnis")
    check(PermissionRecovery.decide(localTrusted: false, freshExitCode: 0, didRestart: false) == .restartNeeded,
        "Frische Freigabe bei altem Prozess löst echten Neustart aus")
    check(PermissionRecovery.decide(localTrusted: false, freshExitCode: 0, didRestart: true) == .restartAlreadyTried,
        "Keine automatische Neustartschleife")
    check(PermissionRecovery.decide(localTrusted: false, freshExitCode: 3, didRestart: false) == .grantNeeded,
        "Nicht erlaubte App wird nicht als freigegeben dargestellt")
    check(PermissionRecovery.decide(localTrusted: false, freshExitCode: nil, didRestart: false) == .checkFailed,
        "Fehlgeschlagene Prüfung behauptet keine Freigabe")
    check(PermissionRecovery.decide(localTrusted: false, freshExitCode: 15, didRestart: false) == .checkFailed,
        "Abgebrochene Prüfung behauptet keine Freigabe")
    // Recorded on the user's 1470×956 display while Mission Control was open.
    let previewSize = CGSize(width: 168.38912133891213, height: 129)
    let recorded = LayoutRules.spaceFrame(center: CGPoint(x: 309, y: 119.5), size: previewSize)
    check(abs(recorded.minX - 224.80543933054394) < 0.001, "Gemessenen Kachelmittelpunkt nach links korrigieren")
    check(recorded.minY == 55, "Gemessenen Kachelmittelpunkt nach oben korrigieren")
    check(recorded.midX == 309 && recorded.midY == 119.5, "Mittelpunkt der Kachel erhalten")
    let lastRecorded = LayoutRules.spaceFrame(center: CGPoint(x: 1161, y: 119.5), size: previewSize)
    check(abs(recorded.union(lastRecorded).midX - 735) < 0.001, "Gemessene Kachelreihe bleibt auf dem Bildschirm zentriert")
    let recordedTile = TileLayout(space: fullscreen, frame: recorded)
    check(recordedTile.closeFrame.minY == 59 && abs(recordedTile.closeFrame.maxX - (recorded.maxX - 4)) < 0.001,
        "X sitzt oben rechts an der tatsächlichen Vorschau")
    check(recorded.contains(recordedTile.closeFrame), "Dauerhaftes X vollständig in der Kachel")
    check(CleanupRules.canRemoveSpace(type: 4, targetWindowPresent: false, anotherAppPresent: false, readSucceeded: true),
        "Nachweislich leerer Vollbildbereich kann entfernt werden")
    check(!CleanupRules.canRemoveSpace(type: 4, targetWindowPresent: true, anotherAppPresent: false, readSucceeded: true),
        "Offene Speicher-Rückfrage schützt den Vollbildbereich")
    check(!CleanupRules.canRemoveSpace(type: 4, targetWindowPresent: false, anotherAppPresent: true, readSucceeded: true),
        "Andere App in Split View schützt den Bereich")
    check(!CleanupRules.canRemoveSpace(type: 0, targetWindowPresent: false, anotherAppPresent: false, readSucceeded: true),
        "Normaler Schreibtisch wird nie entfernt")
    check(!CleanupRules.canRemoveSpace(type: 4, targetWindowPresent: false, anotherAppPresent: false, readSucceeded: false),
        "Fehlende Fenstermetadaten erlauben kein Entfernen")
    check(!CleanupRules.canRemoveSpace(type: nil, targetWindowPresent: false, anotherAppPresent: false, readSucceeded: true),
        "Unbekannter Bereich wird nie entfernt")
    check(CleanupRules.isContentWindow(layer: 0, width: 1470, height: 923), "Echtes Vollbildfenster schützt seinen Bereich")
    check(!CleanupRules.isContentWindow(layer: 1001, width: 28, height: 28), "X-Overlay ist kein fremdes Inhaltsfenster")
    check(!CleanupRules.isContentWindow(layer: 24, width: 1470, height: 33), "Menüleiste blockiert Bereinigung nicht")
    check(CleanupRules.isContentWindow(layer: 0, width: 20, height: 20), "Auch kleine Fenster einer fremden App schützen den Bereich")
    _ = router.down(button: .secondary, contextMenu: false, point: x, tiles: [tile], requestMenu: true)
    check(router.up(button: .secondary, point: x, tiles: [tile]).intent?.contextMenu == true,
        "Rechtsklick direkt auf X verwendet dieselbe globale Eingabeverarbeitung")
    check(!router.drag(button: .primary, point: x), "Fremde Ziehbewegung wird nicht abgefangen")
    var close = CloseProgress()
    check(close.observe(pending: true, dialogs: [], elapsed: 0.7) == .waiting,
        "Noch laufende App nach 0.7 Sekunden löst keinen Fensterwechsel aus")
    check(close.observe(pending: true, dialogs: [], elapsed: 5) == .waiting,
        "Langsames Beenden ohne Dialog öffnet kein Fenster")
    check(!close.hasFocusedDialog, "Warten erzeugt keine fingierte Rückfrage")
    check(close.observe(pending: false, dialogs: [], elapsed: 6) == .finished,
        "Tatsächlich beendete App schließt den Vorgang ab")
    var confirm = CloseProgress()
    check(confirm.observe(pending: true, dialogs: [11], elapsed: 0.3) == .focus(11),
        "Echte neue Rückfrage wird direkt adressiert")
    check(confirm.observe(pending: true, dialogs: [11], elapsed: 0.8) == .waiting,
        "Derselbe Dialog wird nicht ständig erneut fokussiert")
    check(confirm.observe(pending: true, dialogs: [12], elapsed: 1.2) == .focus(12),
        "Weitere echte Speichern-Rückfrage wird erkannt")
    check(confirm.observe(pending: false, dialogs: [12], elapsed: 2) == .finished,
        "Abschluss hat Vorrang vor veralteten Dialoginformationen")
    var cancel = CloseProgress()
    _ = cancel.observe(pending: true, dialogs: [20], elapsed: 0.3)
    check(cancel.observe(pending: true, dialogs: [], elapsed: 0.8) == .waiting,
        "Nach Dialogende kurz auf Abschluss warten")
    check(cancel.observe(pending: true, dialogs: [], elapsed: 1.9) == .dialogDismissed,
        "Abgebrochene Rückfrage hält weitere Schließversuche nicht 90 Sekunden gesperrt")
    var timeout = CloseProgress()
    check(timeout.observe(pending: true, dialogs: [], elapsed: 90) == .timedOut,
        "Nicht beendete App wird nie zwangsweise geschlossen oder blind aktiviert")
    check(DialogRules.isBlocking(role: "AXSheet", modal: false), "Echtes Sheet erkennen")
    check(DialogRules.isBlocking(role: "AXWindow", modal: true), "Separaten Dialog erkennen")
    check(!DialogRules.isBlocking(role: "AXWindow", modal: false),
        "Normales App-Fenster ist kein Speichern-Dialog")
    check(DialogRules.isBlocking(role: "AXGroup", modal: nil, subrole: "AXDialog", focused: true),
        "Fokussierter semantischer Office-Dialog ohne Modal-Attribut wird erkannt")
    check(!DialogRules.isBlocking(role: "AXWindow", modal: nil, focused: true),
        "Fokussiertes normales Dokument ohne Modal-Attribut wird nicht aktiviert")
    check(!DialogRules.isBlocking(role: "AXWindow", modal: false, subrole: "AXDialog", focused: true),
        "Explizit nichtmodaler Suchdialog löst keinen erzwungenen Fensterwechsel aus")
    check(!DialogRules.isBlocking(role: "AXGroup", modal: nil, subrole: "AXDialog", focused: false),
        "Unsicheres nicht fokussiertes Dialogobjekt ohne Modalität wird nicht geraten")
    var reused = CloseProgress()
    check(reused.observe(pending: true, dialogs: [42], elapsed: 0.3) == .focus(42),
        "Echte Rückfrage darf dieselbe AX-Kennung wie eine frühere UI verwenden")
    let primary = ScreenRecord(id: 1, uuid: "physical-1", frame: screen)
    let secondary = ScreenRecord(id: 2, uuid: "physical-2", frame: second)
    check(ScreenRecord.matching([primary, secondary], displayID: nil, point: CGPoint(x: 300, y: 50))?.id == 1,
        "Fehlende AXDisplayID wird bei Anzeige und Bereinigung gleich zugeordnet")
    check(ScreenRecord.matching([primary, secondary], displayID: nil, point: CGPoint(x: -1500, y: -100))?.id == 2,
        "Geometrie-Zuordnung funktioniert auch auf zweiter Anzeige")
    check(ScreenRecord.matching([primary], displayID: 99, point: CGPoint(x: 300, y: 50)) == nil,
        "Explizit falsche Display-ID wird nicht überschrieben")
    check(ScreenRecord.matching([primary, primary], displayID: nil, point: CGPoint(x: 300, y: 50)) == nil,
        "Mehrdeutige Anzeige wird nicht geraten")
    var reads = 0
    let sorted = LayoutRules.measureAndSort(Array((0..<40).reversed())) { item in
        reads += 1
        return CGRect(x: item * 50, y: 0, width: 40, height: 30)
    }
    check(reads == 40, "Vierzig Kacheln werden genau vierzig Mal vermessen, nicht im Sortiervergleich")
    check(sorted.map(\.item) == Array(0..<40), "Lokale Sortierung erhält korrekte Leistenreihenfolge")
    let filtered = LayoutRules.measureAndSort([1, 2, 3]) { $0 == 2 ? nil : CGRect(x: $0 * 50, y: 0, width: 40, height: 30) }
    check(filtered.count == 2, "Nicht lesbare Kachel erzeugt keinen erfundenen Rahmen")
    check(LayoutRules.map(spaces: [desktop, fullscreen, SpaceRecord(id: 8, type: 4)],
        frames: filtered.map(\.frame), screen: screen) == nil, "Unvollständig gemessene Leiste bleibt geschützt")
    let catalog = WindowCatalog(rows: [
        benchmarkRow(id: 1, pid: 10), benchmarkRow(id: 2, pid: 10), benchmarkRow(id: 3, pid: 11),
        benchmarkRow(id: 4, pid: 12, layer: 24), benchmarkRow(id: 5, pid: 13, width: 28)
    ])
    check(catalog.owners(of: [1, 2, 3, 4, 5, 99]) == [10: [1, 2], 11: [3]],
        "Einmalig erstellter Fensterindex bewahrt Prozesszuordnung und filtert Leisten/Overlays")
    check(catalog.owners(of: [2]) == [10: [2]], "Index verwendet nur Fenster des jeweils abgefragten Spaces")
    check(catalog.owners(of: []).isEmpty, "Leerer Space erbt keine Fenster aus dem Index")
    print("\(passed) Prüfungen bestanden.")
}

private func benchmarkRow(id: Int, pid: Int, layer: Int = 0, width: Int = 1000) -> [String: Any] {
    [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
     kCGWindowLayer as String: NSNumber(value: layer), kCGWindowBounds as String:
        CGRect(x: 0, y: 0, width: width, height: 800).dictionaryRepresentation]
}

func runCatalogBenchmark() {
    let rows = (1...2000).map { benchmarkRow(id: $0, pid: $0 % 50 + 100, layer: $0 % 9 == 0 ? 24 : 0) }
    let memberships = (0..<40).map { space in Set((1...2000).filter { $0 % 40 == space }.map { CGWindowID($0) }) }
    let iterations = 20
    var oldCount = 0, indexedCount = 0
    var start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations {
        for ids in memberships {
            for row in rows {
                guard let id = row[kCGWindowNumber as String] as? NSNumber, ids.contains(id.uint32Value),
                      let layer = row[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 150, rect.height >= 100 else { continue }
                oldCount += 1
            }
        }
    }
    let oldTime = ProcessInfo.processInfo.systemUptime - start
    start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations {
        let catalog = WindowCatalog(rows: rows)
        for ids in memberships { indexedCount += catalog.owners(of: ids).values.reduce(0) { $0 + $1.count } }
    }
    let newTime = ProcessInfo.processInfo.systemUptime - start
    guard oldCount == indexedCount else { fputs("Benchmark-Ergebnisse weichen ab.\n", stderr); exit(1) }
    print("Synthetischer Fensterindex-Test: 2000 Fenster, 40 Spaces, \(iterations) Durchläufe")
    print(String(format: "Vorher: %.1f ms; Index: %.1f ms; Faktor: %.2f; gleiche Treffer: %d", oldTime * 1000, newTime * 1000, oldTime / max(newTime, 0.000001), oldCount))
    print("Misst nur Metadatenverarbeitung, keine reale Mission-Control-Einblendzeit.")
}

