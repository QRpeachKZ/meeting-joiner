import AppKit
import Combine
import MeetingJoinerCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MeetingJoinerApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = MeetingJoinerApplicationDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class MeetingJoinerApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = MeetingJoinerAppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var reminderSubscription: AnyCancellable?
    private var observedPendingIDs = Set<String>()
    private var isShowingReminder = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: "video", accessibilityDescription: "Meeting Joiner")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("Meeting Joiner")
            button.toolTip = "Meeting Joiner"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(
            model: model, openSettings: { [weak self] in self?.openSettings(nil) }
        ))
        // Published emits before storage changes; read the queue on the next run-loop turn.
        reminderSubscription = model.$pendingReminders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.pendingRemindersDidChange(self.model.pendingReminders)
            }
        model.start()
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }
        isShowingReminder = !model.pendingReminders.isEmpty
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.title = "Meeting Joiner"
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func pendingRemindersDidChange(_ reminders: [Meeting]) {
        let ids = Set(reminders.map(\.id))
        let hasNewReminder = !ids.subtracting(observedPendingIDs).isEmpty
        observedPendingIDs = ids
        if ids.isEmpty {
            if isShowingReminder { popover.performClose(nil) }
            isShowingReminder = false
        } else if hasNewReminder {
            // Only new IDs reopen a dismissed popover; metadata updates do not.
            showPopover()
        }
    }

    @objc func openSettings(_ sender: Any?) {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Meeting Joiner Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.contentMinSize = NSSize(width: 520, height: 480)
            window.setContentSize(NSSize(width: 560, height: 720))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(sender) }
        settingsWindow?.makeKeyAndOrderFront(sender)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "Meeting Joiner")
        let appItem = NSMenuItem(title: "Meeting Joiner", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        appMenu.addItem(withTitle: "About Meeting Joiner",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Meeting Joiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
    }
}

@MainActor
final class MeetingJoinerAppModel: NSObject, ObservableObject {
    @Published var settings: ExchangeSettings
    @Published var exchangeLogin: String
    @Published var exchangePasswordDraft = ""
    @Published var clearExchangePassword = false
    @Published var status = "Not connected"
    @Published var meetings: [Meeting] = []
    @Published private(set) var pendingReminders: [Meeting] = []
    @Published private(set) var isSyncing = false

    private let defaults = UserDefaults.standard
    private let reminderCoordinator: ReminderCoordinator
    private let localGoogleOAuthConfiguration: GoogleOAuthDesktopClientConfiguration?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var savedConfiguration: CalendarSyncConfiguration
    private var snapshots = CalendarMeetingSnapshots()
    private var syncFlight = CalendarSyncFlight()
    private var settingsSaveError: String?
    private var timer: Timer?
    private var reminderTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var hasStarted = false

    override init() {
        localGoogleOAuthConfiguration = Self.discoverLocalGoogleOAuthConfiguration()
        let storedSettings: ExchangeSettings
        if let data = UserDefaults.standard.data(forKey: "exchange-settings"),
           let stored = try? JSONDecoder().decode(ExchangeSettings.self, from: data) {
            storedSettings = stored
        } else {
            storedSettings = ExchangeSettings()
        }
        settings = storedSettings
        exchangeLogin = storedSettings.login
        savedConfiguration = CalendarSyncConfiguration(exchange: storedSettings)
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: "dismissed-meeting-reminders") ?? [])
        reminderCoordinator = ReminderCoordinator(opener: WorkspaceConferenceOpener(), dismissedMeetingIDs: dismissed)
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        scheduleSyncTimer()
        let reminderTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkReminders() }
        }
        self.reminderTimer = reminderTimer
        RunLoop.main.add(reminderTimer, forMode: .common)
        wakeObserver = workspaceNotifications.addObserver(forName: NSWorkspace.didWakeNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkReminders() }
        }
        Task { await syncNow() }
    }

    deinit {
        timer?.invalidate()
        reminderTimer?.invalidate()
        if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }
    }

    var googleOAuthConfigurationStatus: String {
        localGoogleOAuthConfiguration != nil
            ? "Локальная конфигурация Google OAuth найдена."
            : "Конфигурация Google OAuth не найдена или некорректна. Поместите файл client_secret*.json для Desktop OAuth рядом с Package.swift и перезапустите приложение."
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

    @discardableResult
    func saveSettings() -> Bool {
        do {
            var exchange = settings
            try exchange.setLogin(exchangeLogin)
            let candidate = CalendarSyncConfiguration(exchange: exchange)
            try candidate.validate()
            let data = try JSONEncoder().encode(candidate.exchange)
            var secretUpdates: [SettingsSecretUpdate] = []
            if candidate.exchange.tlsMode == .insecureWarning {
                secretUpdates.append(SettingsSecretUpdate(account: "exchange.password", value: nil))
            } else if !exchangePasswordDraft.isEmpty {
                secretUpdates.append(SettingsSecretUpdate(account: "exchange.password", value: Data(exchangePasswordDraft.utf8)))
            } else if clearExchangePassword {
                secretUpdates.append(SettingsSecretUpdate(account: "exchange.password", value: nil))
            }
            let secretsChanged = try SettingsSecretBatch.apply(secretUpdates, load: { account in
                try KeychainStore.load(account: account)
            }, write: { value, account in
                if let value {
                    try KeychainStore.save(value, account: account)
                } else {
                    try KeychainStore.delete(account: account)
                }
            })
            defaults.set(data, forKey: "exchange-settings")
            snapshots.remove(providers: candidate.changedSources(from: savedConfiguration))
            syncFlight.settingsDidSave(from: savedConfiguration, to: candidate, secretsChanged: secretsChanged)
            savedConfiguration = candidate
            settings = candidate.exchange
            exchangeLogin = candidate.exchange.login
            meetings = snapshots.meetings
            checkReminders()
            exchangePasswordDraft = ""
            clearExchangePassword = false
            settingsSaveError = nil
            status = "Settings saved"
            scheduleSyncTimer()
            return true
        } catch {
            let message = "Settings not saved: \(error.localizedDescription)"
            settingsSaveError = message
            status = message
            return false
        }
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
            guard saveSettings() else { return }
            status = "Client certificate imported to Keychain"
        } catch { status = error.localizedDescription }
    }

    func connectGoogle() {
        guard let localGoogleOAuthConfiguration else {
            status = googleOAuthConfigurationStatus
            return
        }
        guard saveSettings() else { return }
        let revision = syncFlight.revision
        let clientID = localGoogleOAuthConfiguration.clientID
        let clientSecret = localGoogleOAuthConfiguration.clientSecret
        status = "Waiting for Google authorization…"
        Task {
            do {
                let callback = try await GoogleAuthorizationFlow().authorize(clientID: clientID)
                guard googleAuthorizationIsCurrent(revision) else { return }
                try Task.checkCancellation()
                let service = GoogleOAuthService(clientID: clientID, clientSecret: clientSecret)
                let token = try await service.exchangeAuthorizationCode(callback.code, verifier: callback.verifier, redirectURI: callback.redirectURI)
                guard googleAuthorizationIsCurrent(revision) else { return }
                try Task.checkCancellation()
                try KeychainGoogleTokenStore().saveToken(token)
                snapshots.remove(providers: [CalendarSyncConfiguration.googleProviderName])
                meetings = snapshots.meetings
                checkReminders()
                syncFlight.configurationDidChange()
                status = settingsSaveError ?? "Google Calendar connected"
                await syncNow()
            } catch {
                guard googleAuthorizationIsCurrent(revision) else { return }
                status = "Google sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    private func googleAuthorizationIsCurrent(_ revision: UInt) -> Bool {
        guard syncFlight.isCurrent(revision) else {
            status = "Google sign-in cancelled because settings or the connected account changed. Please sign in again."
            return false
        }
        return true
    }

    func syncNow() async {
        checkReminders()
        guard var revision = syncFlight.begin() else { return }
        isSyncing = true
        defer { isSyncing = false }
        while true {
            await performSync(revision: revision)
            guard let nextRevision = syncFlight.finish() else { return }
            revision = nextRevision
        }
    }

    private func performSync(revision: UInt) async {
        let configuration = savedConfiguration
        do {
            try configuration.validateInterval()
        } catch {
            status = "Invalid saved settings: \(error.localizedDescription)"
            return
        }
        var providers: [any MeetingCalendarProvider] = []
        var preparationFailures: [CalendarSyncFailure] = []
        if let localGoogleOAuthConfiguration {
            do {
                guard try KeychainGoogleTokenStore().loadToken() != nil else {
                    throw CalendarProviderError.api("Connect Google Calendar in Settings")
                }
                providers.append(GoogleCalendarProvider(clientID: localGoogleOAuthConfiguration.clientID,
                                                        clientSecret: localGoogleOAuthConfiguration.clientSecret,
                                                        tokenStore: KeychainGoogleTokenStore()))
            } catch {
                preparationFailures.append(CalendarSyncFailure(provider: CalendarSyncConfiguration.googleProviderName,
                                                               message: error.localizedDescription))
            }
        } else if !configuration.isExchangeEnabled {
            preparationFailures.append(CalendarSyncFailure(provider: CalendarSyncConfiguration.googleProviderName,
                                                           message: googleOAuthConfigurationStatus))
        }
        if configuration.isExchangeEnabled {
            do {
                let exchange = configuration.exchange
                try exchange.validate()
                let password = exchange.tlsMode == .insecureWarning ? ""
                    : (try KeychainStore.loadSecret(account: "exchange.password")) ?? ""
                guard exchange.tlsMode == .insecureWarning || !password.isEmpty else {
                    throw CalendarProviderError.api("Save an Exchange password in Settings")
                }
                let session = URLSession(configuration: .ephemeral,
                                         delegate: ExchangeSecurityDelegate(settings: exchange), delegateQueue: nil)
                providers.append(EWSCalendarProvider(settings: exchange, password: password, session: session))
            } catch {
                preparationFailures.append(CalendarSyncFailure(provider: CalendarSyncConfiguration.exchangeProviderName,
                                                               message: error.localizedDescription))
            }
        }
        let startedAt = Date()
        let networkReport = await CalendarSyncService(providers: providers).syncReport(
            from: startedAt.addingTimeInterval(-86_400), to: startedAt.addingTimeInterval(7 * 86_400))
        guard syncFlight.isCurrent(revision) else { return }
        let report = CalendarSyncReport(successfulSnapshots: networkReport.successfulSnapshots,
                                        failures: preparationFailures + networkReport.failures)
        snapshots.apply(report, now: Date())
        meetings = snapshots.meetings
        checkReminders()
        if let settingsSaveError {
            status = settingsSaveError
            return
        }
        let syncedAt = Date.now.formatted(date: .omitted, time: .shortened)
        let errors = report.failures.map { "\($0.provider): \($0.message)" }.joined(separator: "; ")
        if report.successfulProviderCount == 0 {
            status = report.failures.isEmpty ? "Configure a calendar provider in Settings" : "Calendar sync failed: " + errors
        } else if report.failures.isEmpty {
            status = "Synced \(meetings.count) meeting(s) at \(syncedAt)"
        } else {
            status = "Partially synced at \(syncedAt); \(errors)"
        }
    }

    private func checkReminders() {
        let now = Date()
        _ = reminderCoordinator.remindersToShow(for: meetings, now: now)
        let pending = reminderCoordinator.pendingReminders(for: meetings, now: now)
        if pending != pendingReminders { pendingReminders = pending }
    }

    func connect(_ meeting: Meeting) {
        // Re-resolve against the latest snapshot rather than opening a stale view's URL.
        if let current = meetings.first(where: { $0.id == meeting.id }), current.end > Date() {
            _ = reminderCoordinator.handle(.connect, for: current)
        }
        checkReminders()
    }

    func skip(_ meeting: Meeting) {
        _ = reminderCoordinator.handle(.skip, for: meeting)
        persistDismissedMeetingIDs()
        checkReminders()
    }

    private func scheduleSyncTimer() {
        timer?.invalidate()
        guard hasStarted else { return }
        let minutes = savedConfiguration.exchange.syncIntervalMinutes
        guard (1...1_440).contains(minutes) else { return }
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func persistDismissedMeetingIDs() {
        defaults.set(Array(reminderCoordinator.dismissedMeetingIDs), forKey: "dismissed-meeting-reminders")
    }
}

private struct WorkspaceConferenceOpener: ConferenceURLOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

private struct PopoverContentView: View {
    @ObservedObject var model: MeetingJoinerAppModel
    let openSettings: () -> Void
    @State private var showsMeetingList = false

    var body: some View {
        VStack(spacing: 12) {
            if let meeting = model.pendingReminders.first, !showsMeetingList {
                ReminderContentView(model: model, meeting: meeting,
                                    remainingCount: model.pendingReminders.count - 1)
                    .id(meeting.id)
                Button("Все встречи") { showsMeetingList = true }
                    .buttonStyle(.link)
            } else {
                ViewThatFits(in: .vertical) {
                    meetingList.fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        meetingList
                    }
                    .frame(height: 448)
                }
                // Including the shared padding, a long menu is at most 480 points tall.
                .frame(maxHeight: 448)
            }
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.pendingReminders.map(\.id)) { _ in showsMeetingList = false }
    }

    private var meetingList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.pendingReminders.isEmpty {
                Button("Вернуться к напоминанию") { showsMeetingList = false }
                    .buttonStyle(.link)
            }
            MenuContentView(model: model, openSettings: openSettings)
        }
    }
}

private struct MeetingCardView: View {
    let meeting: Meeting
    let connect: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(meeting.title)
            Text(meeting.start.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Войти", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(meeting.conferenceURL == nil)
                    .accessibilityIdentifier("meeting-join")
                Button("Пропустить", action: skip)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("meeting-skip")
            }
            .controlSize(.large)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct ReminderContentView: View {
    @ObservedObject var model: MeetingJoinerAppModel
    let meeting: Meeting
    let remainingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Встреча началась", systemImage: "video").font(.headline)
            MeetingCardView(meeting: meeting,
                            connect: { model.connect(meeting) }, skip: { model.skip(meeting) })
            if remainingCount > 0 {
                Text("Ещё \(remainingCount) встреч")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-reminder")
    }
}

private struct RefreshButton: View {
    @ObservedObject var model: MeetingJoinerAppModel
    @State private var rotation = 0.0
    @State private var isAnimating = false
    private let rotationDuration: TimeInterval = 0.9

    private var isBusy: Bool { isAnimating || model.isSyncing }

    var body: some View {
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help("Обновить календари")
        .accessibilityLabel("Обновить календари")
    }

    private func refresh() {
        guard !isBusy else { return }
        isAnimating = true
        withAnimation(.linear(duration: rotationDuration)) { rotation = 360 }
        Task { @MainActor in
            let startedAt = Date()
            await model.syncNow()
            let remaining = rotationDuration - Date().timeIntervalSince(startedAt)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rotation = 0
                isAnimating = false
            }
        }
    }
}

private struct MenuContentView: View {
    @ObservedObject var model: MeetingJoinerAppModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting Joiner").font(.headline)
                Spacer()
                RefreshButton(model: model)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let current = model.meetings.filter { $0.end > .now }.prefix(8)
            if current.isEmpty {
                Text("Нет предстоящих встреч").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(current)) { meeting in
                        MeetingCardView(meeting: meeting,
                                        connect: { model.connect(meeting) }, skip: { model.skip(meeting) })
                    }
                }
            }
            Divider()
            HStack {
                Button("Настройки…", action: openSettings)
                Spacer()
                Button("Выйти") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: MeetingJoinerAppModel
    var body: some View {
        Form {
            Section("Google Calendar") {
                Text(model.googleOAuthConfigurationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Войти через Google") { model.connectGoogle() }
            }
            Section("On-prem Exchange (EWS)") {
                TextField("Server URL", text: $model.settings.serverURL, prompt: Text("https://exchange.example.org"))
                TextField("Port", value: $model.settings.port, format: .number)
                TextField("Логин (DOMAIN\\USERNAME)", text: $model.exchangeLogin, prompt: Text("MOSCOW\\U_M1ABC"))
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
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 520)
    }
}
