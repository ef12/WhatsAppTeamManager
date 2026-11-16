# Android WhatsApp reader protocol spike

The Android app has two reader paths behind the shared Flutter reader contract. The native `WhatsAppNotificationReaderService` reads text notifications from WhatsApp installed on the same device; this source cannot provide old chat history or structured poll votes. The packaged Go `whatsmeow` bridge connects as a WhatsApp linked device and provides structured messages, polls, voters, and reactions when WhatsApp sends those protocol events. The Settings reader offers a separate linked-device pairing and group selector for that poll-capable path. Its real-device poll/vote and reconnect behavior still requires end-to-end verification.

For notification capture, the user enables notification access in Android Settings, selects one observed group, and explicitly confirms the group notice before message text is retained. Other groups contribute only their names to the local selection list. The selected group's cache is limited to 5,000 messages and 30 days in private app storage; changing the selected group clears the old group's message cache. Linked-device session data is stored separately in app-private `files/whatsapp-spike/` storage.

Notification access provides only the text and sender details WhatsApp includes in notifications. It cannot backfill existing chat history, and it does not expose a structured poll or complete voter list. WhatsApp notification preview settings control which message text is available. This prototype also does not yet provide the planned foreground-service controls or battery/restart recovery guarantees. The Go `whatsmeow` bridge in this directory is an earlier linked-device experiment and is no longer the Android app's active reader path.

## Rebuild the retired linked-device spike

Requires Go 1.26+, `gomobile`, Android SDK/NDK, and the project Go dependencies. From this directory:

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_NDK_HOME = "$env:ANDROID_HOME\ndk\28.2.13676358"
gomobile bind -target=android -androidapi 26 -o bridge.aar .
```

This rebuilds the AAR packaged by the Android app at `flutter_app/android/app/build.gradle.kts`.

## Linked-device protocol spike

The Go bridge can pair as a linked device and process history batches, live messages, polls, votes, and reactions when WhatsApp sends those protocol events. A prior already-linked emulator session did not receive a requested history batch. Treat historical recovery as best-effort; live structured poll capture must be verified with a test poll and vote changes before using it for attendance.

`whatsmeow` is an unofficial WhatsApp Web protocol client. Pairing and continued use may fail or risk account restrictions.
