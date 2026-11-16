import 'dart:io';

import 'whatsapp_message_reader.dart';
import 'windows_whatsapp_message_reader.dart';

WindowsWhatsAppMessageReader? _windowsReader;
AndroidWhatsAppMessageReader? _androidReader;

WhatsAppMessageReader createWhatsAppMessageReader() {
  if (Platform.isAndroid)
    return _androidReader ??= AndroidWhatsAppMessageReader();
  if (Platform.isWindows)
    return _windowsReader ??= WindowsWhatsAppMessageReader();
  throw UnsupportedError(
    'WhatsApp reader is available on Android and Windows.',
  );
}
