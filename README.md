# Meeting Joiner

A native macOS menu-bar app that syncs Google Calendar and on-premises Microsoft Exchange (EWS) meetings and reminds you at meeting start. It never joins a call automatically: a recognized video-conference URL opens in the system browser only after you choose **Connect**. **Skip** dismisses that meeting's reminder.

## Requirements and build

- macOS 13 or later
- Xcode Command Line Tools with Swift 5.9 or later

Build and test the app bundle on macOS:

```sh
./scripts/build-app.sh
swift test
open .build/MeetingJoinerApp.app
```

The script creates an unsigned `.app` bundle suitable for local testing; this project does not package or sign an installer.

The app appears in the menu bar. Open **Settings…** to configure either or both calendar providers. Sync runs at the configured Exchange interval (and when requested from the menu); reminders are generated for meetings that have just started. macOS notification permission is required for start reminders.

## Google Calendar setup

1. In Google Cloud Console, create or select a project, enable the Google Calendar API, and configure the OAuth consent screen for the intended users.
2. Create an OAuth client with application type **Desktop app**. To avoid manual entry, put Google's downloaded `client_secret*.json` file in the project root next to `Package.swift`; Meeting Joiner discovers it when launched from the built app in `.build`. The file is ignored by Git. Alternatively, enter a client ID (and optional client secret) in Settings; credential fields are masked, and a manually entered secret is stored in Keychain.
3. In Settings, choose **Войти через Google**. Meeting Joiner opens Google's authorization page in the system browser and receives the authorization-code response on a temporary loopback listener (`127.0.0.1`) using PKCE. Grant the read-only Calendar scope.
4. OAuth access and refresh tokens are stored in macOS Keychain. Revoke access from your Google Account if you no longer use the app.

Google restricts OAuth use to registered/verified clients according to your consent-screen audience and publishing status. This project does not bundle a developer's OAuth client ID or secret.

## On-prem Exchange setup

1. Enable and allow access to the Exchange Web Services (EWS) endpoint for the intended account. This MVP uses EWS SOAP `FindItem` with Basic HTTP authentication; Basic authentication must be enabled and accepted by your Exchange deployment. Windows Integrated (NTLM/Kerberos) authentication is not implemented.
2. Enter the EWS server base URL, port, domain, username, and sync interval (1–1440 minutes). The app requests `/EWS/Exchange.asmx` when the URL has no path.
3. Enter the password and save. It is stored in macOS Keychain, never in the project or preferences file.
4. By default, HTTPS certificate validation uses the macOS system trust store. If your organization uses a private CA, choose **System CA plus configured CA** and import its PEM/DER certificate into Keychain. The optional PKCS#12 client identity is imported into macOS Keychain; its passphrase is used only during import.

**Security limits:** certificate validation is enabled for TLS and is never disabled or replaced by accept-all behavior. No-TLS mode is an explicit, visibly warned option, removes any saved Exchange password, and sends no password or Authorization header; it may therefore fail against Exchange. Access/refresh tokens, manually entered Google OAuth client secrets, Exchange passwords, CA certificates, and imported private-key identities are kept in Keychain. A locally discovered OAuth JSON file remains in the project root and is ignored by Git; its client ID and secret are not displayed in Settings or emitted in app status/log messages. Nonsecret provider settings are stored in the user's macOS preferences. No credentials are written to tracked source files.

## Provider and reminder boundaries

`MeetingCalendarProvider` is the provider boundary. Google Calendar OAuth/API and Exchange EWS SOAP implementations independently produce normalized `Meeting` values; `CalendarSyncService` combines and sorts them. `ReminderCoordinator` deduplicates meeting-start reminders, tracks Skip, and delegates URL opening through an injected opener. The UI/notification action handler is the only app path that opens a recognized conference URL, in response to Connect. Recognized hosts include Google Meet, Zoom, Microsoft Teams, Webex, Whereby, and BlueJeans.

## Scope and limitations

- macOS only; no Microsoft Graph, Windows/Linux app, automatic conference join, or signed installer.
- Exchange authentication supports Basic only; configure TLS because Basic credentials are otherwise not protected in transit. No-TLS mode is deliberately unauthenticated.
- Calendar fetches use a bounded date range; all-day event dates and recurring Google events are normalized by the API's expanded-event response.
- Notifications are local macOS notifications. The app needs to be running for its periodic sync/reminder checks.
- This is an MVP; it has unit coverage for configuration, sync merging, conference-link recognition and reminder actions. Live Google/Exchange tenant integration and macOS UI behavior require testing on a configured Mac.
