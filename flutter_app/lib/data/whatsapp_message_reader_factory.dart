import 'dart:io';

import 'whatsapp_message_reader.dart';
import 'windows_whatsapp_message_reader.dart';

WhatsAppMessageReader createWhatsAppMessageReader() {
  if (Platform.isAndroid) return AndroidWhatsAppMessageReader();
  if (Platform.isWindows) return WindowsWhatsAppMessageReader();
  throw UnsupportedError(
    'WhatsApp reader is available on Android and Windows.',
  );
}
