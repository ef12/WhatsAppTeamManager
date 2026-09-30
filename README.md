# RKAVIC Team Manager

A local team manager for Android and Windows, built with Flutter. Plan matches, manage players and parents, record attendance and duties, enter scores, and mark matches done. The app prepares WhatsApp messages for you to review and share manually.

## Features

- Add, edit, and delete players and matches.
- Set kickoff, meetup, address or venue, field number (for example `1B2`), and reply deadline with date and time pickers. Tap the address on a match to open it in Google Maps.
- Record attendance, track each member's participation across events, and assign duties to a player or parent.
- Enter a result, mark a match done, and reopen it later.
- Preview and manually share invitation, poll, reminder, duty, result, and substitute drafts. Invitation and substitute drafts include a Google Maps link when the match has an address or venue. On Android, the share sheet opens. On Windows, the draft is copied and WhatsApp Web opens when you choose that action.
- Export and import a JSON backup to move the complete local team data between Android and Windows.
- Use the same RKAVIC orange design on Android and Windows, with navigation adapted to each screen size.

Each device keeps its own SQLite database. There is no account, cloud sync, automatic WhatsApp sending, or automatic reading of replies.

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
