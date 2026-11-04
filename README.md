# Meeting Joiner

A native macOS menu-bar app that syncs Google Calendar and on-premises Microsoft Exchange (EWS) meetings and opens a reminder popover from its menu-bar icon at meeting start. It never joins a call automatically: **Войти** opens the recognized conference URL, and **Пропустить** dismisses that meeting's reminder.

## Requirements and build

- macOS 13 or later
- Xcode Command Line Tools with Swift 5.9 or later
- A persistent code-signing identity in the login Keychain. The build script prefers a single `Apple Development` identity (recommended, because its stable Team ID gives macOS Keychain a stable partition) and otherwise uses the self-signed `Meeting Joiner Local Development` certificate. A self-signed certificate is sufficient for local signing, but macOS may still request Keychain access after the executable changes. Keep private keys in Keychain, not in this repository. Set `MEETING_JOINER_SIGNING_IDENTITY` to select another existing identity explicitly.

Build and test the app bundle on macOS:

```sh
./scripts/build-app.sh
swift test
open .build/MeetingJoinerApp.app
```

The script signs and verifies the `.app` bundle with the selected persistent identity, without falling back to ad-hoc signing. Reuse the same certificate, Team ID, and bundle identifier across rebuilds. For prompt-free Keychain access after rebuilds, use an Apple Development identity; a self-signed certificate can still trigger a partition-ID prompt when the executable changes. This local signature is not Developer ID distribution or notarization; the project does not package or sign an installer.

The app appears in the menu bar. Open **Settings…** to configure either or both calendar providers. Sync runs at the saved interval (and when requested from the menu). Reminders check cached meetings independently every second and after wake, even when sync fails; ended meetings are never announced. The reminder popover does not require macOS notification permission. Simultaneous reminders are shown in order. Clicking outside closes the popover without skipping; click the menu-bar icon to return to pending reminders. Invalid settings are rejected before saving, and unsaved edits do not change synchronization.

Each successful provider refresh replaces only its own cached meetings, including an empty calendar. Failed providers retain their cached, unexpired meetings.

## Google Calendar setup

1. In Google Cloud Console, create or select a project, enable the Google Calendar API, and configure the OAuth consent screen for the intended users.
2. Create an OAuth client with application type **Desktop app**. Put Google's downloaded `client_secret*.json` file in the project root next to `Package.swift`; Meeting Joiner discovers it when launched from the built app in `.build`. The file is ignored by Git. OAuth credentials are not entered or displayed in Settings, and synchronization uses the account's primary calendar.
3. In Settings, choose **Войти через Google**. Meeting Joiner opens Google's authorization page in the system browser and receives the authorization-code response on a temporary loopback listener (`127.0.0.1`) using PKCE. Grant the read-only Calendar scope.
4. Google sign-in saves the OAuth token in macOS Keychain. Token reads are cached in memory for the lifetime of the app. Refreshing an access token does not write to Keychain when the existing nonempty refresh token is unchanged; new or rotated refresh credentials are persisted. After restarting, an older saved access token may be refreshed again automatically. Signing in again is not required for ordinary synchronization or restarting the app, unless Google revokes or expires the authorization. Revoke access from your Google Account if you no longer use the app.

Google restricts OAuth use to registered/verified clients according to your consent-screen audience and publishing status. This project does not bundle a developer's OAuth client ID or secret. After switching from an ad-hoc build or changing the signing identity, macOS may request Keychain access again; choose **Always Allow** for this trusted local app. With an Apple Development identity, subsequent builds using the same Team ID should retain that permission. A self-signed identity may still require approval when the executable changes. Recreating the saved OAuth token under the new identity can be necessary if the old item remains tied to a previous ad-hoc signature. This is separate from Google sign-in.

## On-prem Exchange setup

1. Enable and allow access to the Exchange Web Services (EWS) endpoint for the intended account. This MVP uses EWS SOAP `FindItem` followed by batched `GetItem` requests to retrieve event descriptions, with Basic HTTP authentication; Basic authentication must be enabled and accepted by your Exchange deployment. Windows Integrated (NTLM/Kerberos) authentication is not implemented.
2. Enter the EWS server base URL, port, a single login in `DOMAIN\USERNAME` format (for example, `MOSCOW\U_M1ABC`), and sync interval (1–1440 minutes). Leave the login empty to disable Exchange. The app requests `/EWS/Exchange.asmx` when the URL has no path.
3. Enter the password and save. It is stored in macOS Keychain, never in the project or preferences file.
4. By default, HTTPS certificate validation uses the macOS system trust store. If your organization uses a private CA, choose **System CA plus configured CA** and import its PEM/DER certificate into Keychain. The optional PKCS#12 client identity is imported into macOS Keychain; its passphrase is used only during import. Client-certificate authentication is restricted to the configured HTTPS host and port and is disabled in No-TLS mode.

**Security limits:** certificate validation is enabled for TLS and is never disabled or replaced by accept-all behavior. No-TLS mode is an explicit, visibly warned option, removes any saved Exchange password, and sends no password or Authorization header; it may therefore fail against Exchange. Access/refresh tokens, Exchange passwords, CA certificates, and imported private-key identities are kept in Keychain. A locally discovered OAuth JSON file remains in the project root and is ignored by Git; its client ID and secret are not displayed in Settings or emitted in app status/log messages. Nonsecret provider settings are stored in the user's macOS preferences. No credentials are written to tracked source files.

## Provider and reminder boundaries

`MeetingCalendarProvider` is the provider boundary. Google Calendar OAuth/API and Exchange EWS SOAP implementations independently produce normalized `Meeting` values; `CalendarSyncService` combines and sorts them. `ReminderCoordinator` deduplicates meeting-start reminders, keeps pending reminders, tracks Skip, and delegates URL opening through an injected opener. Only an explicit **Войти** or **Connect** action opens a recognized conference URL. Recognized hosts include Google Meet, Zoom, Microsoft Teams, Webex, Whereby, and BlueJeans.

## Scope and limitations

- macOS only; no Microsoft Graph, Windows/Linux app, automatic conference join, or signed installer.
- Exchange authentication supports Basic only; configure TLS because Basic credentials are otherwise not protected in transit. No-TLS mode is deliberately unauthenticated.
- Calendar fetches use a bounded date range; all-day event dates and recurring Google events are normalized by the API's expanded-event response.
- Exchange paging is not implemented. Truncated responses cause an explicit sync error rather than replacing the cache with an incomplete calendar.
- Reminders are local menu-bar popovers. The app needs to be running for its periodic sync/reminder checks.
- This is an MVP; it has unit coverage for configuration, sync merging, conference-link recognition and reminder actions. Live Google/Exchange tenant integration and macOS UI behavior require testing on a configured Mac.
