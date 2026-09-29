# RKAVIC Team Manager (Android V1)

A local, single-manager app for organizing team matches. Player and match data stays in SQLite on the phone. WhatsApp messages are drafts opened through Android's share sheet; the manager sends them manually and records replies in the app.

## Features

- Add and edit players and parent names.
- Add and edit matches with kickoff, meeting time, location, and attendance deadline.
- Record each player's attendance, assign duties, and mark duties complete.
- Enter RKAVIC and opponent scores; mark a match done or reopen it.
- Draft invitations, reminders, duty announcements, and substitute requests for manual sharing.

The app has no cloud sync, login, parent portal, automatic WhatsApp reply reading, or export.

## Build

Use a full JDK 17 with `javac` and Android SDK 35. In Android Studio, select JDK 17 as the Gradle JDK if its bundled runtime is newer. The checked-in wrapper downloads Gradle 8.13.

On Windows:

```powershell
.\gradlew.bat assembleDebug
```

On macOS or Linux:

```sh
./gradlew assembleDebug
```

The debug APK is at `app/build/outputs/apk/debug/app-debug.apk`. You can also use Android Studio's **Build > Build APK(s)** command.

Gradle creates `app/debug.keystore` on the first debug build. This local test key is ignored by Git. Keep it if you want future debug APKs to install over this build on the same phone. The key is not for release signing.

## Manual APK distribution workflow

In GitHub, open **Actions > Build APK distribution > Run workflow**. The workflow builds and verifies a debug APK, then provides a downloadable artifact containing the APK, `SHA256SUMS`, and `INSTALL.txt`. The artifact is kept for 30 days. It does not publish a GitHub release or send WhatsApp messages.

For APKs from separate workflow runs to install as updates over one another, add a repository Actions secret named `DEBUG_KEYSTORE_BASE64` containing the Base64 encoding of your existing `app/debug.keystore`. That key must use the app's standard debug alias and password (`androiddebugkey` / `android`). Keep the original key in a safe place. If the secret is absent, each run creates a new test key, so its APK is suitable for a fresh install but cannot update a build signed with another key. Uninstalling to change keys deletes the app's local data.

## Install and data

Copy the APK to an Android phone and allow installation from that source, or use Android Studio's **Run** command with USB debugging. An upgrade from the earlier V1 database keeps existing players, matches, attendance, and duties. Uninstalling the app deletes its local database, so back up important data before uninstalling.
