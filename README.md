# RKAVIC Team Manager

A local team manager for Android and Windows, built with Flutter. Plan matches, manage players and parents, record attendance and duties, enter scores, and mark matches done. The app prepares WhatsApp messages for you to review and share manually.

## Features

- Add, edit, and delete players and matches.
- Set kickoff, meetup, address or venue, field number (for example `1B2`), and reply deadline with date and time pickers. Tap the address on a match to open it in Google Maps.
- Record attendance, track each member's participation across events, and assign duties to a player or parent.
- Enter a result, mark a match done, and reopen it later.
- Edit, copy, and manually share invitation, poll, reminder, duty, result, and substitute drafts. Reset restores the generated text. Invitation and substitute drafts include a Google Maps link when the match has an address or venue. On Android, the share sheet opens. On Windows, the edited message is copied and WhatsApp Web opens when you choose that action.
- Export and import a JSON backup to move the complete local team data between Android and Windows.
- Optionally share a team with separate Supabase accounts. Changes sync automatically while the app is open and on resume. Independent edits merge; overlapping edits require a choice.
- Use the same RKAVIC orange design on Android and Windows, with navigation adapted to each screen size.

Each device keeps its own SQLite database. Cloud sync is optional and disabled until configured with a Supabase project. The app does not automatically send WhatsApp messages or read replies.

## Intended personal use and privacy

This app can be used by a small group of team managers acting on their own behalf, not on behalf of RKAVIC or another club. They decide what information to enter and whom to invite. The app stores player and parent names, match information, attendance, results, and duties on each device. If cloud sync is configured, it uploads a snapshot accessible to authenticated members of the shared team. It does not send this database to the app publisher.

The app can generate message drafts from this information. You can edit each draft before copying or sharing it. It never sends a message or reads WhatsApp replies. The manager chooses whether to copy and send a draft to the team's private WhatsApp group. A sent draft can contain information derived from the app, such as match details, attendance reminders, results, or duty assignments; review it before sharing. WhatsApp processes messages sent through its service under its own terms and privacy information.

JSON file backups are created only when a manager chooses to export them. File backups are not encrypted by this app and can contain personal information. Store them somewhere with limited access. If cloud sync is enabled, the app uploads a full JSON snapshot to Supabase. Authenticated team members can access it under row-level access policies. The app does not encrypt the JSON before upload. The owner can remove members and reset the invitation code; a removed member may still retain data already downloaded to their device.

This section describes the manager's intended use; it does not by itself establish that a particular use is exempt from the GDPR or make the app GDPR-compliant. The GDPR excludes processing by a natural person only when it is carried out in the course of a purely personal or household activity. The manager acts independently and not under the club's direction, but whether managing a football team falls within that exemption still depends on the real context. Using a personal device or a private WhatsApp group does not by itself settle the question. See [GDPR Article 2 and Recital 18](https://eur-lex.europa.eu/eli/reg/2016/679/oj) and the [Dutch Data Protection Authority's explanation of legal grounds and personal or household use](https://autoriteitpersoonsgegevens.nl/themas/basis-avg/avg-algemeen/grondslagen-avg-uitgelegd).

The manager does not use the app under the club's instructions, and the club does not receive access to the local app data. This describes the manager's intended arrangement; the actual facts determine the legal position. If that arrangement changes, review who determines the purposes and means of processing and who is responsible for GDPR obligations. See the Dutch Data Protection Authority's guidance on [controllers and processors](https://autoriteitpersoonsgegevens.nl/themas/basis-avg/avg-algemeen/verantwoordelijke-en-verwerker). Avoid recording health details or other sensitive information in the app.

## Set up cloud sync

Cloud sync uses Supabase email and password authentication and stores one versioned snapshot per shared team. Create a Supabase project, then run [`supabase/migrations/202610180001_team_snapshots.sql`](supabase/migrations/202610180001_team_snapshots.sql) followed by [`supabase/migrations/202611150001_shared_teams.sql`](supabase/migrations/202611150001_shared_teams.sql) in that project's SQL Editor. The second migration adds teams, membership policies, invitations, and atomic revision-checked uploads. It also enables Realtime for the shared snapshot table. Do not add a Supabase service-role key to the app; the client uses only the project URL and publishable key.

Enable email/password sign-up in Supabase Authentication. If email confirmation is enabled, confirm the account using the email Supabase sends before signing in on the app. You can enter the project URL and publishable key in the app's Settings screen; the app stores them on that device and shows sign-in immediately. You can also supply them when building or running the app:

```powershell
cd flutter_app
flutter run -d windows --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
flutter run --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

The URL and publishable key are app configuration, not secrets. Never use a secret or service-role key in the app. For GitHub distributions, repository variables named `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` preconfigure Android and Windows builds. Without them, the user can connect the project in Settings. Changing a connected project in Settings takes effect after restarting the app. Keep local JSON export/import available as an independent backup and recovery path.

In Settings, each manager creates an account. One person creates the team and shares its invitation code; the others join with their own accounts. An existing single-user cloud snapshot is copied into the new team when its owner creates it. A new device with no local data downloads the team snapshot. If a joining device already has local data, the app asks which complete copy to keep. After that, local edits upload within about two seconds while the app is open; Realtime and periodic checks fetch others' changes. Separate row edits merge automatically. If the same row changed on both sides, Settings asks which version to keep for each overlapping item. Sync uses local durable storage and retries connection failures. A closed Android app does not promise immediate background sync; it checks again when opened.

## Source layout

`flutter_app/` is the Android and Windows app. The original Kotlin Android project remains in `app/` for reference. New distributions are built from Flutter.

The experimental read-only WhatsApp group reader is in `companion/`. See its README for setup. It runs separately on Windows and is not connected to the Flutter app or team sync yet.

The Flutter Android app keeps the original application ID `nl.rkavic.manager` and database name `team.db`. Version `0.6.1+7` upgrades an installed `0.2` through `0.6` build when signed with the **same key**, retaining its local data. New records receive random IDs so different devices can create records independently. Windows stores a separate database in the user's application support folder.

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
- Windows installer: `flutter_app/build/installer/RKAVIC-Team-Manager-Windows-v0.6.1-Setup.exe`

The Flutter Android debug build uses `app/debug.keystore`. Keep your existing copy to install over an earlier build without deleting data. For a fresh clone, create a debug key at that path using the standard Android debug alias and passwords, or use the manual GitHub workflow to generate one. Signing a production release requires a separate release key and Gradle configuration.

## Manual distributions from GitHub

In **Actions → Build app distributions → Run workflow**, start the workflow. It uploads an Android debug APK and a Windows installer as separate artifacts, each retained for 30 days. Give Windows users the `RKAVIC-Team-Manager-Windows-v0.6.1-Setup.exe` file. It installs for the current user without an administrator prompt, adds a Start Menu shortcut, offers an optional desktop shortcut, and can be removed through Windows Installed Apps. Installing a newer version keeps the local database. Uninstall also leaves that database in the user profile, so it can be used again after reinstalling. The installer is currently unsigned; Windows may show an unrecognized app warning. A [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) may be needed on a PC that does not already have it.

To make the GitHub APK update an installed copy, set the Actions secret `DEBUG_KEYSTORE_BASE64` to the Base64 encoding of the existing `app/debug.keystore`. Without it, each workflow run creates a new debug key and its APK is suitable only for a fresh install. Uninstalling Android app data deletes the local database.
