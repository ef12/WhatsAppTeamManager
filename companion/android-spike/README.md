# Android WhatsApp reader protocol spike

The Android app now reads WhatsApp group notifications from WhatsApp installed on the same device. Its active implementation is the native `WhatsAppNotificationReaderService` registered in `flutter_app/android/app/src/main/AndroidManifest.xml`; the Flutter reader uses the shared `WhatsAppMessageReader` contract. The service requires the user to enable notification access in Android Settings, filters for WhatsApp and WhatsApp Business group notifications, and stores up to 5,000 message texts for 30 days in private app storage.

Notification access provides only the text and sender details WhatsApp includes in notifications. It cannot backfill existing chat history, and it does not expose a structured poll or complete voter list. WhatsApp notification preview settings control which message text is available. The Go `whatsmeow` bridge in this directory is an earlier linked-device experiment and is no longer the Android app's active reader path.

## Rebuild the retired linked-device spike

Requires Go 1.26+, `gomobile`, Android SDK/NDK, and the project Go dependencies. From this directory:

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_NDK_HOME = "$env:ANDROID_HOME\ndk\28.2.13676358"
gomobile bind -target=android -androidapi 26 -o bridge.aar .
```

This creates a standalone AAR for experimenting with `bridge.go`. The app does not package or call this AAR; its Android reader uses notification access.

## Linked-device protocol spike

The Go experiment can pair as a linked device and process history batches, live messages, polls, votes, and reactions when WhatsApp sends those protocol events. However, an already-linked session on the emulator did not receive a requested history batch, so it was replaced in the app by same-device notification capture. This spike remains for reference and is not built into the app's normal Android read flow.

`whatsmeow` is an unofficial WhatsApp Web protocol client. Pairing and continued use may fail or risk account restrictions.
