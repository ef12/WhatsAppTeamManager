# RKAVIC Team Manager

A local team manager for Android and Windows, built with Flutter. Plan matches, manage players and parents, record attendance and duties, enter scores, and mark matches done. The app prepares WhatsApp messages for you to review and share manually.

## Features

- Add, edit, and delete players and matches.
- Set kickoff, meetup, location, and reply deadline with date and time pickers.
- Record attendance and assign duties to a player or parent.
- Enter a result, mark a match done, and reopen it later.
- Preview and manually share invitation, reminder, duty, and substitute drafts. On Android, the share sheet opens. On Windows, the draft is copied and WhatsApp Web opens when you choose that action.

Each device keeps its own SQLite database. There is no account, cloud sync, automatic WhatsApp sending, or automatic reading of replies.

## Source layout

`flutter_app/` is the Android and Windows app. The original Kotlin Android project remains in `app/` for reference. New distributions are built from Flutter.

The Flutter Android app keeps the original application ID `nl.rkavic.manager` and database name `team.db`. Version `0.3.0+3` upgrades an installed `0.2` build when signed with the **same key**, retaining its local data. Windows stores a separate database in the user's application support folder.

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

Build outputs:

- Android: `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`
- Windows: `flutter_app/build/windows/x64/runner/Release/` (distribute the entire folder)

The Flutter Android debug build uses `app/debug.keystore`. Keep your existing copy to install over an earlier build without deleting data. For a fresh clone, create a debug key at that path using the standard Android debug alias and passwords, or use the manual GitHub workflow to generate one. Signing a production release requires a separate release key and Gradle configuration.

## Manual distributions from GitHub

In **Actions → Build app distributions → Run workflow**, start the workflow. It uploads an Android debug APK and a Windows ZIP as separate artifacts, each retained for 30 days. Extract the whole Windows ZIP and run `rkavic_manager.exe`. You may need the [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) on the destination PC.

To make the GitHub APK update an installed copy, set the Actions secret `DEBUG_KEYSTORE_BASE64` to the Base64 encoding of the existing `app/debug.keystore`. Without it, each workflow run creates a new debug key and its APK is suitable only for a fresh install. Uninstalling Android app data deletes the local database.
