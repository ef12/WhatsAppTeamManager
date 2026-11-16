# WhatsApp reader prototype

This Windows companion captures text messages, polls, and reactions from one active group at a time into a local SQLite database. It publishes the linked account's full group list for the Flutter app, where the active group can be changed while the companion is running; the companion then loads recent messages and updates its selection. In command-line mode, choose to display and save all available text messages from today plus polls created today or with votes updated today, or only the latest available message. It displays reactions and who reacted under imported messages, and reports live reaction changes with the target message when available. If a poll is shown, the reader displays the current voter choices for the full poll. Sender, voter, and reaction display names are resolved from WhatsApp's contact and LID-to-phone mapping and stored separately from sender IDs. Poll questions and choices are saved, and current vote selections are recorded when WhatsApp exposes them. Live vote changes are also printed. Imported and live messages are deduplicated, but already-saved messages are still displayed during the import. The command-line mode also supports sending text to the selected group after typing `SEND` to confirm; the reader does not change RKAVIC team data. It asks for confirmation that group members were informed before pairing. Messages older than 30 days are deleted at startup and when new messages arrive. Media is not imported.

The Flutter Windows app starts this companion in managed app mode, handles the capture notice in the app, displays pairing QR codes in the reader screen, and loads/switches groups through the shared reader interface. The command-line scripts remain available for development and recovery; the normal app flow does not require running them separately.

The reader uses the unofficial `whatsapp-web.js` client. WhatsApp can change its private Web protocol, and use may lead to account restrictions. Use a test group/account first and stop if the risk is unacceptable.

## Run on Windows

1. Install Node.js 22.13 or newer.
2. Install Google Chrome if it is not already installed.
3. Run `install-reader.cmd` once to install the pinned packages.
4. Run `start-companion.cmd`.
5. Confirm the group notice by typing `YES`.
6. Scan the QR code from WhatsApp → Linked devices → Link a device.
7. Select one group. Later runs ask whether to keep capturing that group.
8. Choose `1` to display/save today's text messages and polls created or voted on today, `2` for only the latest message (and all current votes if it is a poll), or press Enter to skip the import.
9. At the message prompt, type a message, review the selected group, and type `SEND` to send it. Type `/exit` to stop the reader, or press Ctrl+C.

The linked-device session, selected group, and SQLite database are stored under `%LOCALAPPDATA%\RKAVICTeamManager\whatsapp-reader`, outside the repository. Keep access to that Windows account private. To unlink the companion, remove it in WhatsApp → Linked devices and delete that local folder.

This prototype has no Flutter inbox yet. Today's messages and polls are printed in the PowerShell window and stored locally in `messages.sqlite`; poll choices are in `poll_json` and the latest selections per voter are in `captured_poll_votes`. Vote details are best-effort and may depend on WhatsApp Web exposing them. The import is limited to history WhatsApp has made available to the linked device; it cannot retrieve messages WhatsApp has not synced.
