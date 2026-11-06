import SwiftUI
import ServiceManagement

enum CloseBehavior: String, CaseIterable, Identifiable {
    case quitApp, closeWindow
    var id: String { rawValue }
    var title: String { self == .quitApp ? "App beenden" : "Nur Vollbildfenster schließen" }
}

// ObservableObject keeps this small utility compatible with macOS 13.
// The delegate owns the instance; the settings view only observes it.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { save(enabled, "enabled"); onEnabled?(enabled) } }
    @Published var showMenuBar: Bool { didSet { save(showMenuBar, "showMenuBar"); onMenuBar?(showMenuBar) } }
    @Published var showDock: Bool { didSet { save(showDock, "showDock"); onDock?(showDock) } }
    @Published var closeBehavior: CloseBehavior { didSet { save(closeBehavior.rawValue, "closeBehavior") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var trusted = false
    @Published var checkingPermission = false
    @Published var permissionMessage = ""
    @Published var status = "Wird gestartet …"
    @Published var actionMessage = ""
    @Published var loginMessage = ""
    var onEnabled: ((Bool) -> Void)?
    var onMenuBar: ((Bool) -> Void)?
    var onDock: ((Bool) -> Void)?
    var onLogin: ((Bool) -> Void)?
    var onAccessibility: (() -> Void)?
    var onRecheckPermission: (() -> Void)?
    var onRestart: (() -> Void)?
    var onQuit: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        showMenuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
        showDock = defaults.object(forKey: "showDock") as? Bool ?? false
        closeBehavior = CloseBehavior(rawValue: defaults.string(forKey: "closeBehavior") ?? "") ?? .quitApp
    }
    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SpaceClose").font(.title2.bold())
                    Text("Vollbild-Apps direkt in Mission Control schließen.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()
            Form {
                Section {
                    Toggle("SpaceClose aktivieren", isOn: $preferences.enabled)
                        .help("Zeigt Schließen-Schaltflächen in der oberen Vollbildleiste von Mission Control.")
                    Toggle("Beim Anmelden starten", isOn: Binding(
                        get: { preferences.launchAtLogin },
                        set: { preferences.onLogin?($0) }))
                    if !preferences.loginMessage.isEmpty {
                        Text(preferences.loginMessage).font(.callout).foregroundStyle(.secondary)
                    }
                } header: { Text("Allgemein") }

                Section {
                    Toggle("Symbol in der Menüleiste anzeigen", isOn: $preferences.showMenuBar)
                    Toggle("App im Dock anzeigen", isOn: $preferences.showDock)
                } header: { Text("Darstellung") } footer: {
                    Text("Das X bleibt in der aufgeklappten Vollbildleiste immer oben rechts sichtbar. Diese Einstellungen erreichst du auch bei ausgeblendeten Symbolen, indem du SpaceClose erneut öffnest.")
                }

                Section {
                    Picker("Klick auf X", selection: $preferences.closeBehavior) {
                        ForEach(CloseBehavior.allCases) { behavior in Text(behavior.title).tag(behavior) }
                    }
                    .pickerStyle(.menu)
                    if !preferences.actionMessage.isEmpty {
                        Text(preferences.actionMessage).font(.callout).foregroundStyle(.secondary)
                            .accessibilityLabel("Letzter Schließversuch: \(preferences.actionMessage)")
                    }
                } header: { Text("Schließen") } footer: {
                    Text(preferences.closeBehavior == .quitApp
                        ? "Beendet die gewählte App mit allen Fenstern. Rückfragen zum Speichern bleiben erhalten. Per Rechtsklick kannst du eine andere Aktion wählen."
                        : "Schließt nur das zugehörige Vollbildfenster. Falls macOS das Fenster nicht bereitstellt, erscheint ein Hinweis; die App wird nicht ersatzweise beendet.")
                }

                Section {
                    LabeledContent("Bedienungshilfen") {
                        Label(preferences.trusted ? "Erlaubt" : "Zugriff erforderlich",
                            systemImage: preferences.trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(preferences.trusted ? Color.green : Color.secondary)
                    }
                    Button("Bedienungshilfen öffnen …") { preferences.onAccessibility?() }
                    if !preferences.trusted {
                        Button(preferences.checkingPermission ? "Freigabe wird geprüft …" : "Freigabe prüfen und übernehmen") {
                            preferences.onRecheckPermission?()
                        }.disabled(preferences.checkingPermission)
                        Button("SpaceClose neu starten") { preferences.onRestart?() }
                    }
                    if !preferences.permissionMessage.isEmpty {
                        Text(preferences.permissionMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(preferences.status).font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel("Status: \(preferences.status)")
                } header: { Text("Zugriff") } footer: {
                    Text("Aktiviere SpaceClose in der macOS-Liste. Falls es fehlt, füge SpaceClose aus dem Ordner Programme über + hinzu. Die App sendet keine Daten ins Internet.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Version 0.5.1 · Testversion").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("SpaceClose beenden") { preferences.onQuit?() }
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 640, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
