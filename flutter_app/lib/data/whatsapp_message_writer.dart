import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Platform-neutral handoff for an edited WhatsApp draft.
///
/// The operating system still asks the user to choose a chat and press Send.
/// This deliberately does not send to a recipient in the background.
abstract interface class WhatsAppMessageWriter {
  Future<String> handoffDraft(String message);
}

WhatsAppMessageWriter createWhatsAppMessageWriter() {
  if (Platform.isAndroid) return AndroidWhatsAppMessageWriter();
  if (Platform.isWindows) return WindowsWhatsAppMessageWriter();
  throw UnsupportedError(
    'WhatsApp drafts are available on Android and Windows.',
  );
}

class AndroidWhatsAppMessageWriter implements WhatsAppMessageWriter {
  @override
  Future<String> handoffDraft(String message) async {
    await SharePlus.instance.share(ShareParams(text: message));
    return 'Choose the WhatsApp group, review the draft, and tap Send in WhatsApp.';
  }
}

class WindowsWhatsAppMessageWriter implements WhatsAppMessageWriter {
  @override
  Future<String> handoffDraft(String message) async {
    await Clipboard.setData(ClipboardData(text: message));
    final opened = await launchUrl(
      Uri.parse('https://web.whatsapp.com/'),
      mode: LaunchMode.externalApplication,
    );
    return opened
        ? 'Draft copied. Choose the WhatsApp group, paste the draft, review it, and send.'
        : 'Draft copied. Open WhatsApp Web, choose the group, paste the draft, and send.';
  }
}
