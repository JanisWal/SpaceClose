# SpaceClose 0.5.1 – Performance und Office-Rückfragen

6. November 2026 · build 8 · Apple Silicon

## Bestätigte Ausgangsbasis

Der Nutzer bestätigte die Funktion von 0.5.0 im sichtbaren Einsatz: X richtig positioniert, App/Fenster schließt, Rückfrage-Fokus grundsätzlich funktioniert, geschlossene Kachel verschwindet. Offen waren teils etwa zehn Sekunden Einblendverzögerung, Ruckeln bei vielen Fenstern und ein nicht automatisch aktivierter Word-Speicherdialog. Schließen, Platzierung und der Ablauf zum Vermeiden schwarzer Kacheln werden beibehalten.

## Gefundene Kosten und Änderungen

- AXUIElementSetMessagingTimeout war nur auf Hauptelementen gesetzt. Laut Apples AXUIElement.h gilt eine solche Frist nur für das jeweilige Objekt und wird nicht auf andere/gleiche Unterelemente übertragen. Alle Lesehelfer setzen die Frist jetzt am tatsächlich gelesenen Objekt. Aktionen haben eigene passende Fristen. Damit werden die zuvor möglichen mehrsekündigen Standardwartezeiten einzelner Kinder vermieden.
- Die Sortierung las AXPosition/AXSize innerhalb des Vergleichs wiederholt und danach erneut. Jetzt erfolgt genau eine gebündelte Geometrie-/Rollenabfrage pro Kachel, anschließend ausschließlich lokale Sortierung. Test: 40 Elemente = genau 40 Messaufrufe.
- Der Suchlauf durch Dock/WindowManager begann vorher immer von vorn und konnte viele fremde UI-Knoten besuchen. Bekannte Pfade werden jetzt nur mit geprüften aktuellen Eltern-/Kind-Verbindungen wiederverwendet. Die Erstsuche ist zeitlich/knotenmäßig begrenzt, priorisiert Mission-Control-Gruppen und steigt nicht in Dock-Symbole oder Fenster-Vorschaubäume ein. Insbesondere werden Kinder ausgeschlossener Gruppen nicht vorab angefordert.
- Fensterdaten werden einmal in einen Index eingelesen, dann per Fenster-ID zugeordnet, statt jede Space-Abfrage erneut über alle Fenster-Dictionaries laufen zu lassen. Renderer-Zuordnungen bleiben höchstens 0.6 Sekunden im Cache; geänderte Space-IDs und Bildschirmereignisse invalidieren ihn. Vor dem Schließen wird weiterhin ohne diesen Cache validiert.
- Layout- und Schließ-/Dialogarbeit laufen auf verschiedenen seriellen Queues mit jeweils eigenem Reader. Eine langsame Office-Dialogabfrage blockiert keine Kachelpositionsmessung mehr. Die frühere pauschale Verwerfung eines mehr als 0.6 Sekunden laufenden Durchlaufs ist entfernt; veraltete Generationen nach Aktionen/Bildschirmwechseln werden weiterhin verworfen.
- Die nominale Leerlauf-Abfrage wurde von 0.45 auf 0.2 Sekunden verkürzt. Unveränderte Overlay-Beschriftungen werden nicht laufend neu geschrieben. Bestätigte Ausschluss-Tags werden pro Panel wiederverwendet statt bei jedem Rendern synchron auf dem Hauptthread gelesen. Beim Schließen/Verlassen der Übersicht werden die Panels weiterhin vollständig freigegeben.

## Mögliche Word-Ausfallpfade

Die alte Vorab-Erfassung konnte nach Überschreiten ihres Budgets die gesamte spätere Dialogprüfung ausschalten. Sie erfasste zudem sämtliche Fenster-/Kindidentitäten; ein von Office wiederverwendetes UI-Objekt konnte deshalb als angeblich schon bestehend herausgefiltert werden. Beide Abhängigkeiten sind entfernt.

Erst nach einer tatsächlich angenommenen Schließanfrage wird nach realer blockierender UI gesucht. Priorität haben das fokussierte Fenster, seine Sheets und die Eltern des fokussierten Bedienelements. Damit kann auch ein unter einer AXGroup eingebetteter Office-Dialog erkannt werden, ohne den Dokumentinhalt zu durchsuchen. Weitere Fenster werden rotierend geprüft, damit ein Zeitbudget kein Fenster am Listenende dauerhaft ausschließt.

Sheets und explizit modale Fenster bleiben starke Nachweise. Fehlt AXModal, wird nur ein semantisch als Dialog ausgewiesenes, zusätzlich fokussiertes Element akzeptiert. Ein gewöhnliches fokussiertes Dokument oder ein explizit nichtmodaler Suchdialog wird weiterhin nicht als Speichern-Rückfrage behandelt. Vor der Aktivierung wird das konkrete Dialogobjekt erneut geprüft. Eine von macOS abgelehnte App-Aktivierung darf höchstens zweimal wiederholt werden; bei zwischenzeitlichem anderem Mausklick wird der Wiederholungsversuch verworfen. Kein Force Quit und kein automatisches Bestätigen.

Dies behebt konkrete mögliche Ausfälle der Erkennung, ist aber keine Live-Bestätigung für die tatsächlich aufgetretene Word-Darstellung. Word lief beim lesenden App-Inventar nicht. Der Nutzer wählte ausdrücklich „Zunächst ohne Word-Livetest weiterarbeiten“; Word und Testdokumente wurden nicht geöffnet, verändert oder geschlossen.

## Gemessene/automatische Prüfungen

- 86 Logikprüfungen bestanden, einschließlich bisherigem Schließ-/Rückfrage-Verhalten, Geometrie, genau einmaliger Messung pro Kachel, gleicher Prozesszuordnung des Fensterindex und strikter Ablehnung normaler fokussierter Dokumente.
- Synthetischer Fensterindexvergleich: 2.000 Fenster, 40 Space-Mitgliedschaften, 20 Wiederholungen. Vorher 100.5 ms, Index 13.1 ms, Faktor 7.67; identische 35.560 Treffer. Der Vergleich betrifft nur Metadatenverarbeitung und belegt keinen entsprechenden Faktor für die gesamte App oder die reale Einblendzeit.
- Drei unsichtbare eigene Panels: Vorschauschutz zurückgelesen, keine Alle-Spaces-/Vollbild-Hilfsfenster-Bindung, vollständige Freigabe nach jedem Durchlauf. Keine Benutzer-App hierfür geschlossen.
- Apple-Silicon-App kompiliert und lokale Signatur geprüft. DMG-Prüfsumme gültig; schreibgeschützt geöffnet und Version0.5.1/build8, App-Signatur, identischer App-Dateisatz zum getesteten Build, Programme-Link und Anleitung geprüft. Alle86 Prüfungen auch aus der verpackten App bestanden; Laufwerk ausgeworfen.
- Installierte Info.plist rein lesend geprüft: weiterhin0.5.0/build7. Es wurde keine installierte Datei ersetzt. Code-Differenz zur bestätigten Grundversion: Aenderungen-Code-0.5.1.patch.

## Verbleibender Praxistest

0.5.1 wurde nicht anstelle der Nutzer-App installiert. Die tatsächliche Einblendzeit und Ruckelfreiheit unter vielen offenen Fenstern sowie genau die Word-Speicherabfrage sind noch nicht live gemessen/bestätigt. Die bereits funktionierende 0.5.0 bleibt als Release- und Quellcode-Archiv verfügbar.

Technische Primärreferenz für die Timeout-Semantik: Apples lokales AXUIElement.h, Funktion AXUIElementSetMessagingTimeout; [offizielle API-Dokumentation](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout). Gebündelte Abfragen: AXUIElementCopyMultipleAttributeValues aus demselben SDK. Es werden keine Dokumenttexte, Fenstertitel oder Tastatureingaben protokolliert.
