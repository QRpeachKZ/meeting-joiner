import AppKit
import Combine
import MeetingJoinerCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@main
struct MeetingJoinerApp: App {
    @StateObject private var model = MeetingJoinerAppModel()

    var body: some Scene {
        MenuBarExtra("Meeting Joiner", systemImage: "video") {
            MenuContentView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class MeetingJoinerAppModel: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    @Published var settings: ExchangeSettings
    @Published var googleClientID = ""
    @Published var googleCalendarID = "primary"
    @Published var exchangePasswordDraft = ""
    @Published var googleClientSecretDraft = ""
    @Published var clearExchangePassword = false
    @Published var status = "Not connected"
    @Published var meetings: [Meeting] = []

    private let defaults = UserDefaults.standard
    private let notificationCenter = UNUserNotificationCenter.current()
    private let reminderCoordinator: ReminderCoordinator
    private var timer: Timer?

    override init() {
        if let data = UserDefaults.standard.data(forKey: "exchange-settings"),
           let stored = try? JSONDecoder().decode(ExchangeSettings.self, from: data) {
            settings = stored
        } else {
            settings = ExchangeSettings()
        }
        googleClientID = UserDefaults.standard.string(forKey: "google-client-id") ?? ""
        googleCalendarID = UserDefaults.standard.string(forKey: "google-calendar-id") ?? "primary"
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: "dismissed-meeting-reminders") ?? [])
        reminderCoordinator = ReminderCoordinator(opener: WorkspaceConferenceOpener(), dismissedMeetingIDs: dismissed)
        super.init()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let category = UNNotificationCategory(identifier: Self.reminderCategory,
                                              actions: [
                                                UNNotificationAction(identifier: "CONNECT", title: "Connect", options: [.foreground]),
                                                UNNotificationAction(identifier: "SKIP", title: "Skip", options: [])
                                              ], intentIdentifiers: [], options: [.customDismissAction])
        notificationCenter.setNotificationCategories([category])
        scheduleSyncTimer()
        Task { await syncNow() }
    }

    static let reminderCategory = "MEETING_JOINER_REMINDER"

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "exchange-settings") }
        defaults.set(googleClientID, forKey: "google-client-id")
        defaults.set(googleCalendarID, forKey: "google-calendar-id")
        do {
            if settings.tlsMode == .insecureWarning {
                try KeychainStore.delete(account: "exchange.password")
                exchangePasswordDraft = ""
                clearExchangePassword = false
            } else if !exchangePasswordDraft.isEmpty {
                try KeychainStore.saveSecret(exchangePasswordDraft, account: "exchange.password")
                exchangePasswordDraft = ""
            } else if clearExchangePassword {
                try KeychainStore.delete(account: "exchange.password")
                clearExchangePassword = false
            }
            if !googleClientSecretDraft.isEmpty {
                try KeychainStore.saveSecret(googleClientSecretDraft, account: "google.client-secret")
                googleClientSecretDraft = ""
            }
            status = "Settings saved"
            scheduleSyncTimer()
        } catch { status = error.localizedDescription }
    }

    func importCA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.message = "Import a PEM or DER CA certificate into macOS Keychain"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try KeychainStore.importCACertificate(from: url, label: "Meeting Joiner Exchange CA")
            settings.customCALabel = "Meeting Joiner Exchange CA"
            saveSettings()
        } catch { status = error.localizedDescription }
    }

    func importClientCertificate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.message = "Select a PKCS#12 (.p12/.pfx) client identity to import into macOS Keychain"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "PKCS#12 passphrase"
        alert.informativeText = "The passphrase is used only to import the identity into Keychain and is not saved."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            settings.clientIdentityLabel = try KeychainStore.importClientIdentity(from: url, passphrase: field.stringValue)
            saveSettings()
            status = "Client certificate imported to Keychain"
        } catch { status = error.localizedDescription }
    }

    func connectGoogle() {
        guard !googleClientID.isEmpty else { status = "Enter a Google OAuth desktop client ID first"; return }
        saveSettings()
        status = "Waiting for Google authorization…"
        Task {
            do {
                let callback = try await GoogleAuthorizationFlow().authorize(clientID: googleClientID)
                let secret = try KeychainStore.loadSecret(account: "google.client-secret")
                let service = GoogleOAuthService(clientID: googleClientID, clientSecret: secret)
                let token = try await service.exchangeAuthorizationCode(callback.code, verifier: callback.verifier, redirectURI: callback.redirectURI)
                try KeychainGoogleTokenStore().saveToken(token)
                status = "Google Calendar connected"
                await syncNow()
            } catch { status = "Google sign-in failed: \(error.localizedDescription)" }
        }
    }

    func syncNow() async {
        saveSettingsIfNeeded()
        var providers: [any MeetingCalendarProvider] = []
        if !googleClientID.isEmpty, (try? KeychainGoogleTokenStore().loadToken()) != nil {
            providers.append(GoogleCalendarProvider(clientID: googleClientID,
                                                    clientSecret: try? KeychainStore.loadSecret(account: "google.client-secret"),
                                                    calendarID: googleCalendarID,
                                                    tokenStore: KeychainGoogleTokenStore()))
        }
        let exchangePassword = (try? KeychainStore.loadSecret(account: "exchange.password")) ?? ""
        let exchangeCanRunWithoutPassword = settings.tlsMode == .insecureWarning
        if !settings.username.isEmpty,
           (exchangeCanRunWithoutPassword || !exchangePassword.isEmpty),
           (try? settings.validate()) != nil {
            let configuration = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: configuration, delegate: ExchangeSecurityDelegate(settings: settings), delegateQueue: nil)
            providers.append(EWSCalendarProvider(settings: settings, password: exchangePassword, session: session))
        }
        guard !providers.isEmpty else { status = "Configure a calendar provider in Settings"; return }
        let now = Date()
        let report = await CalendarSyncService(providers: providers).syncReport(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(7 * 86_400))
        guard report.successfulProviderCount > 0 else {
            status = "Calendar sync failed: " + report.failures.map { "\($0.provider): \($0.message)" }.joined(separator: "; ")
            return
        }
        if report.failures.isEmpty {
            meetings = report.meetings
        } else {
            var retained = Dictionary(uniqueKeysWithValues: meetings.filter { $0.end > now }.map { ($0.id, $0) })
            for meeting in report.meetings { retained[meeting.id] = meeting }
            meetings = retained.values.sorted { $0.start < $1.start }
        }
        reminderCoordinator.retainDismissedIDs(keeping: Set(meetings.map(\.id)))
        persistDismissedMeetingIDs()
        let syncedAt = Date.now.formatted(date: .omitted, time: .shortened)
        if report.failures.isEmpty {
            status = "Synced \(meetings.count) meeting(s) at \(syncedAt)"
        } else {
            let errors = report.failures.map { "\($0.provider): \($0.message)" }.joined(separator: "; ")
            status = "Partially synced at \(syncedAt); \(errors)"
        }
        let due = reminderCoordinator.remindersToShow(for: meetings, now: now,
                                                     lookBack: Double(settings.syncIntervalMinutes * 60 + 60))
        for meeting in due { showReminder(for: meeting) }
    }

    func connect(_ meeting: Meeting) {
        _ = reminderCoordinator.handle(.connect, for: meeting)
    }

    func skip(_ meeting: Meeting) {
        _ = reminderCoordinator.handle(.skip, for: meeting)
        persistDismissedMeetingIDs()
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [meeting.id])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            if let meeting = meetings.first(where: { $0.id == id }) {
                switch action {
                case "CONNECT": connect(meeting)
                case "SKIP", UNNotificationDismissActionIdentifier: skip(meeting)
                default: break
                }
            }
            completionHandler()
        }
    }

    private func scheduleSyncTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, min(1_440, settings.syncIntervalMinutes)) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
    }

    private func showReminder(for meeting: Meeting) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting starting: \(meeting.title)"
        content.body = meeting.conferenceURL == nil ? "This event has no recognized video-conference link." : "Connect when you're ready, or skip this reminder."
        content.categoryIdentifier = Self.reminderCategory
        content.sound = .default
        let request = UNNotificationRequest(identifier: meeting.id, content: content, trigger: nil)
        notificationCenter.add(request)
    }

    private func saveSettingsIfNeeded() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "exchange-settings") }
    }

    private func persistDismissedMeetingIDs() {
        defaults.set(Array(reminderCoordinator.dismissedMeetingIDs), forKey: "dismissed-meeting-reminders")
    }
}

private struct WorkspaceConferenceOpener: ConferenceURLOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

private struct MenuContentView: View {
    @ObservedObject var model: MeetingJoinerAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Meeting Joiner").font(.headline)
                Spacer()
                Button { Task { await model.syncNow() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Sync calendars")
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            let current = model.meetings.filter { $0.end > .now }.prefix(8)
            if current.isEmpty { Text("No upcoming meetings").foregroundStyle(.secondary) }
            ForEach(Array(current)) { meeting in
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title).fontWeight(.medium)
                    Text(meeting.start.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if meeting.conferenceURL != nil { Button("Connect") { model.connect(meeting) } }
                        Button("Skip") { model.skip(meeting) }
                    }.buttonStyle(.bordered)
                }
                Divider()
            }
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: MeetingJoinerAppModel
    var body: some View {
        Form {
            Section("Google Calendar") {
                Text("Sign in to let Meeting Joiner read your Google Calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("OAuth desktop client ID (required)", text: $model.googleClientID)
                Text("A Google OAuth Desktop app client ID is required. Meeting Joiner does not bundle one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Calendar ID", text: $model.googleCalendarID)
                SecureField("OAuth client secret (optional)", text: $model.googleClientSecretDraft)
                Button("Войти через Google") { model.connectGoogle() }
            }
            Section("On-prem Exchange (EWS)") {
                TextField("Server URL", text: $model.settings.serverURL, prompt: Text("https://exchange.example.org"))
                TextField("Port", value: $model.settings.port, format: .number)
                TextField("Domain", text: $model.settings.domain)
                TextField("Username", text: $model.settings.username)
                SecureField("Password (saved to Keychain)", text: $model.exchangePasswordDraft)
                Toggle("Remove saved Exchange password", isOn: $model.clearExchangePassword)
                Picker("TLS security", selection: $model.settings.tlsMode) {
                    ForEach(ExchangeTLSMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if model.settings.tlsMode == .customCA {
                    Button("Import CA certificate to Keychain…") { model.importCA() }
                }
                Button("Import optional client certificate…") { model.importClientCertificate() }
                if let warning = model.settings.securityWarning {
                    Text(warning).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Text("Sync interval")
                    TextField("Minutes", value: $model.settings.syncIntervalMinutes, format: .number).frame(width: 80)
                    Text("minutes (1–1440)")
                }
            }
            Section {
                HStack {
                    Button("Save Settings") { model.saveSettings() }
                    Button("Sync Now") { Task { await model.syncNow() } }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 660)
    }
}
