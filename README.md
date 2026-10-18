# RKAVIC Team Manager

A local team manager for Android and Windows, built with Flutter. Plan matches, manage players and parents, record attendance and duties, enter scores, and mark matches done. The app prepares WhatsApp messages for you to review and share manually.

## Features

- Add, edit, and delete players and matches.
- Set kickoff, meetup, address or venue, field number (for example `1B2`), and reply deadline with date and time pickers. Tap the address on a match to open it in Google Maps.
- Record attendance, track each member's participation across events, and assign duties to a player or parent.
- Enter a result, mark a match done, and reopen it later.
- Preview and manually share invitation, poll, reminder, duty, result, and substitute drafts. Invitation and substitute drafts include a Google Maps link when the match has an address or venue. On Android, the share sheet opens. On Windows, the draft is copied and WhatsApp Web opens when you choose that action.
- Export and import a JSON backup to move the complete local team data between Android and Windows.
- Optionally sync the complete team snapshot between devices using a private Supabase account. Sync runs after edits, when the app resumes, and on demand; simultaneous edits produce a conflict choice instead of a silent overwrite.
- Use the same RKAVIC orange design on Android and Windows, with navigation adapted to each screen size.

Each device keeps its own SQLite database. Cloud sync is optional and disabled until configured with a Supabase project. The app does not automatically send WhatsApp messages or read replies.

## Intended personal use and privacy

This app is used by an individual football team manager on the manager's own behalf, not on behalf of RKAVIC or another club. The manager independently decides whether to use the app and what information to enter. The manager keeps the team data for personal use and does not give the club or other people access to the app or its local database. The app stores player and parent names, match information, attendance, results, and duties on the device. It does not send this database to the app publisher. If cloud sync is configured, it uploads a snapshot to the manager's signed-in Supabase account as described below.

The app can generate message drafts from this information. It never sends a message or reads WhatsApp replies. The manager chooses whether to copy and send a draft to the team's private WhatsApp group. A sent draft can contain information derived from the app, such as match details, attendance reminders, results, or duty assignments; review it before sharing. WhatsApp processes messages sent through its service under its own terms and privacy information.

JSON file backups are created only when the manager chooses to export them. File backups are not encrypted by this app and can contain personal information. Store them somewhere with access limited to you, and delete copies when they are no longer needed. If cloud sync is configured and enabled, the app uploads a full JSON team snapshot to the authenticated manager's private Supabase account. The snapshot is protected by Supabase account-level access policies and TLS in transit, but the app does not encrypt the JSON before upload. Cloud sync is therefore optional; use it only if comfortable storing this team data with that provider.

This section describes the manager's intended use; it does not by itself establish that a particular use is exempt from the GDPR or make the app GDPR-compliant. The GDPR excludes processing by a natural person only when it is carried out in the course of a purely personal or household activity. The manager acts independently and not under the club's direction, but whether managing a football team falls within that exemption still depends on the real context. Using a personal device or a private WhatsApp group does not by itself settle the question. See [GDPR Article 2 and Recital 18](https://eur-lex.europa.eu/eli/reg/2016/679/oj) and the [Dutch Data Protection Authority's explanation of legal grounds and personal or household use](https://autoriteitpersoonsgegevens.nl/themas/basis-avg/avg-algemeen/grondslagen-avg-uitgelegd).

The manager does not use the app under the club's instructions, and the club does not receive access to the local app data. This describes the manager's intended arrangement; the actual facts determine the legal position. If that arrangement changes, review who determines the purposes and means of processing and who is responsible for GDPR obligations. See the Dutch Data Protection Authority's guidance on [controllers and processors](https://autoriteitpersoonsgegevens.nl/themas/basis-avg/avg-algemeen/verantwoordelijke-en-verwerker). Avoid recording health details or other sensitive information in the app.

## Set up cloud sync

Cloud sync uses Supabase email and password authentication and stores one versioned full-team snapshot per signed-in account. Create a Supabase project, then run [`supabase/migrations/202610180001_team_snapshots.sql`](supabase/migrations/202610180001_team_snapshots.sql) in that project's SQL Editor. The migration creates a private per-user snapshot table, a read policy limited to the signed-in user, and an atomic revision-checked upload function. Do not add a Supabase service-role key to the app; the client uses only the project URL and publishable key.

Enable email/password sign-up in Supabase Authentication. If email confirmation is enabled, confirm the account using the email Supabase sends before signing in on the app. Then run the app with the project settings:

```powershell
cd flutter_app
flutter run -d windows --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
flutter run --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

The URL and publishable key are app configuration, not secrets. Never use the service-role key in a client build. For GitHub distributions, define repository variables named `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`; the workflow passes them into Android and Windows builds. Without these variables, cloud sync stays unavailable in those builds. Keep local JSON export/import available as an independent backup and recovery path.

The first device with local team data uploads it if the cloud account has no snapshot. A newly installed device with an empty database downloads an existing snapshot. If both the device and cloud already have data on first sign-in, or both have changed since their last sync, the app asks which complete copy to keep. It does not merge individual records. After a restore, the app updates its local database transactionally. Android and Windows are configured in this repository; the Supabase Flutter client also supports iOS, so the same sync service can be reused when an iOS app target is added.

## Source layout

`flutter_app/` is the Android and Windows app. The original Kotlin Android project remains in `app/` for reference. New distributions are built from Flutter.

The Flutter Android app keeps the original application ID `nl.rkavic.manager` and database name `team.db`. Version `0.5.0+5` upgrades an installed `0.2`, `0.3`, or `0.4` build when signed with the **same key**, retaining its local data. Existing matches gain an empty field number that can be filled in later. Windows stores a separate database in the user's application support folder.

## Build locally

Install Flutter 3.47.5 and its [Android](https://docs.flutter.dev/platform-integration/android/setup) or [Windows](https://docs.flutter.dev/platform-integration/windows/setup) prerequisites. Windows builds need Visual Studio with Desktop development with C++ and Windows Developer Mode enabled for plugin symlinks.

```powershell
cd flutter_app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build windows --release
```

To create the Windows installer after the release build, install Inno Setup 6 and run:

```powershell
.\packaging\build_windows_installer.ps1
```

Build outputs:

- Android: `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`
- Windows app files: `flutter_app/build/windows/x64/runner/Release/`
- Windows installer: `flutter_app/build/installer/RKAVIC-Team-Manager-Windows-v0.5.0-Setup.exe`

The Flutter Android debug build uses `app/debug.keystore`. Keep your existing copy to install over an earlier build without deleting data. For a fresh clone, create a debug key at that path using the standard Android debug alias and passwords, or use the manual GitHub workflow to generate one. Signing a production release requires a separate release key and Gradle configuration.

## Manual distributions from GitHub

In **Actions → Build app distributions → Run workflow**, start the workflow. It uploads an Android debug APK and a Windows installer as separate artifacts, each retained for 30 days. Give Windows users the `RKAVIC-Team-Manager-Windows-v0.5.0-Setup.exe` file. It installs for the current user without an administrator prompt, adds a Start Menu shortcut, offers an optional desktop shortcut, and can be removed through Windows Installed Apps. Installing a newer version keeps the local database. Uninstall also leaves that database in the user profile, so it can be used again after reinstalling. The installer is currently unsigned; Windows may show an unrecognized app warning. A [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) may be needed on a PC that does not already have it.

To make the GitHub APK update an installed copy, set the Actions secret `DEBUG_KEYSTORE_BASE64` to the Base64 encoding of the existing `app/debug.keystore`. Without it, each workflow run creates a new debug key and its APK is suitable only for a fresh install. Uninstalling Android app data deletes the local database.
