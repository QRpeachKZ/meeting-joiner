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
    private let localGoogleOAuthConfiguration: GoogleOAuthDesktopClientConfiguration?
    private var timer: Timer?

    override init() {
        localGoogleOAuthConfiguration = Self.discoverLocalGoogleOAuthConfiguration()
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

    var hasLocalGoogleOAuthConfiguration: Bool { localGoogleOAuthConfiguration != nil }

    var isUsingLocalGoogleOAuthConfiguration: Bool {
        hasLocalGoogleOAuthConfiguration && googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveGoogleClientID: String {
        if isUsingLocalGoogleOAuthConfiguration {
            return localGoogleOAuthConfiguration?.clientID ?? ""
        }
        return googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func effectiveGoogleClientSecret() -> String? {
        if isUsingLocalGoogleOAuthConfiguration {
            return localGoogleOAuthConfiguration?.clientSecret
        }
        return try? KeychainStore.loadSecret(account: "google.client-secret")
    }

    private static func discoverLocalGoogleOAuthConfiguration() -> GoogleOAuthDesktopClientConfiguration? {
        let appDirectories = [
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent()
        ].compactMap { $0 }
        guard let projectRoot = GoogleOAuthDesktopClientConfiguration.projectRoot(
            containingPackageFrom: appDirectories
        ) else { return nil }
        return GoogleOAuthDesktopClientConfiguration.discover(inProjectDirectory: projectRoot)
    }

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
        let clientID = effectiveGoogleClientID
        guard !clientID.isEmpty else {
            status = "Add a valid local Google Desktop OAuth file or enter a client ID in Settings"
            return
        }
        saveSettings()
        status = "Waiting for Google authorization…"
        Task {
            do {
                let callback = try await GoogleAuthorizationFlow().authorize(clientID: clientID)
                let service = GoogleOAuthService(clientID: clientID, clientSecret: effectiveGoogleClientSecret())
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
        let clientID = effectiveGoogleClientID
        if !clientID.isEmpty, (try? KeychainGoogleTokenStore().loadToken()) != nil {
            providers.append(GoogleCalendarProvider(clientID: clientID,
                                                    clientSecret: effectiveGoogleClientSecret(),
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

    private var upcomingMeetings: [Meeting] {
        model.meetings.filter { $0.end > .now }
    }

    private var visibleMeetings: [Meeting] {
        Array(upcomingMeetings.prefix(8))
    }

    private enum StatusPresentation {
        case failure, warning, success, progress, info

        var icon: String {
            switch self {
            case .failure: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.triangle"
            case .success: return "checkmark.circle.fill"
            case .progress: return "person.crop.circle.badge.clock"
            case .info: return "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .failure: return .red
            case .warning, .progress: return .orange
            case .success: return .green
            case .info: return Color(nsColor: .secondaryLabelColor)
            }
        }
    }

    private var statusPresentation: StatusPresentation {
        let status = model.status.lowercased()
        if status.contains("partially synced") { return .warning }
        if status.contains("fail") || status.contains("error") { return .failure }
        if status.contains("configure a calendar provider") || status.contains("add a valid local google") { return .warning }
        if status.isEmpty || status == "not connected" { return .info }
        if status == "settings saved" || status.hasPrefix("synced ") || status.hasPrefix("google calendar connected") || status.hasPrefix("client certificate imported") {
            return .success
        }
        if status.contains("waiting") || status.contains("authorization") { return .progress }
        return .info
    }

    private var statusIcon: String { statusPresentation.icon }
    private var statusTint: Color { statusPresentation.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusView
            meetingsContent
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Joiner").font(.headline)
                Text("Calendar reminders").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.syncNow() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Sync calendars")
            .accessibilityLabel("Sync calendars")
        }
    }

    private var statusView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var meetingsContent: some View {
        if upcomingMeetings.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Upcoming").font(.headline)
                    Spacer()
                    Text(upcomingMeetings.count == 1 ? "1 meeting" : "\(upcomingMeetings.count) meetings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                meetingList
                if upcomingMeetings.count > 8 {
                    Text("Showing the next 8 meetings.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var meetingList: some View {
        if upcomingMeetings.count <= 4 {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleMeetings) { meeting in
                    MeetingMenuRow(meeting: meeting,
                                   onConnect: { model.connect(meeting) },
                                   onSkip: { model.skip(meeting) })
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleMeetings) { meeting in
                        MeetingMenuRow(meeting: meeting,
                                       onConnect: { model.connect(meeting) },
                                       onSkip: { model.skip(meeting) })
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No upcoming meetings")
                .font(.headline)
            Text("Connect Google Calendar or Exchange in Settings to see your schedule.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var footer: some View {
        HStack {
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit (⌘Q)")
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

private struct MeetingMenuRow: View {
    let meeting: Meeting
    let onConnect: () -> Void
    let onSkip: () -> Void

    private var isHappeningNow: Bool {
        meeting.start <= .now && meeting.end > .now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Label(meeting.start.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isHappeningNow {
                    Text("Now")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                } else if meeting.conferenceURL != nil {
                    Image(systemName: "video.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Has a conference link")
                }
            }
            HStack(spacing: 8) {
                if meeting.conferenceURL != nil {
                    Button("Connect", action: onConnect)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Text("No conference link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsView: View {
    @ObservedObject var model: MeetingJoinerAppModel

    var body: some View {
        Form {
            Section("Google Calendar") {
                Text("Connect your Google account to import calendar events. Meeting Joiner requests read-only Calendar access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.isUsingLocalGoogleOAuthConfiguration {
                    Label("Using the local Google Desktop OAuth client", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Credential values are not displayed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.hasLocalGoogleOAuthConfiguration {
                    Label("Local OAuth client available", systemImage: "checkmark.circle")
                        .foregroundStyle(.blue)
                    Text("Clear the client ID override to use the local client_secret*.json file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("No local OAuth client configured", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Enter a client ID below or add a client_secret*.json file next to Package.swift.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Sign in with Google") { model.connectGoogle() }
                    .buttonStyle(.borderedProminent)
                TextField("Calendar ID", text: $model.googleCalendarID)
                DisclosureGroup("Advanced OAuth client overrides") {
                    TextField("OAuth client ID override (optional)", text: $model.googleClientID)
                    SecureField("OAuth client secret override (optional)", text: $model.googleClientSecretDraft)
                    Text("Overrides replace the local client file. The secret is stored in Keychain when you save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Section("On-prem Exchange (EWS)") {
                Text("Connect to Exchange Web Services for on-prem calendars. Basic auth requires HTTPS; no-TLS mode is unauthenticated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                    Text("Imports a CA certificate into Keychain and trusts it in addition to system CAs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Import CA certificate to Keychain…") { model.importCA() }
                }
                Button("Import optional client certificate…") { model.importClientCertificate() }
                Text("Optional mutual-TLS identity for Exchange; the PKCS#12 passphrase is used only during import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = model.settings.securityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Sync interval")
                    TextField("Minutes", value: $model.settings.syncIntervalMinutes, format: .number).frame(width: 80)
                    Text("minutes (1–1440)")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button("Save Settings") { model.saveSettings() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("s", modifiers: .command)
                        Button("Sync Now") { Task { await model.syncNow() } }
                            .keyboardShortcut("r", modifiers: .command)
                        Spacer()
                        Text("⌘S save · ⌘R sync")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 700)
    }
}
