import 'dart:convert';
import 'dart:io';

class CloudSyncConfig {
  const CloudSyncConfig({required this.url, required this.publishableKey});

  static const buildUrl = String.fromEnvironment('SUPABASE_URL');
  static const buildPublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  final String url;
  final String publishableKey;

  bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  static File fileIn(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}supabase_config.json');

  static Future<CloudSyncConfig> load(Directory directory) async {
    final file = fileIn(directory);
    if (await file.exists()) {
      try {
        final value = jsonDecode(await file.readAsString());
        if (value is Map<String, dynamic> &&
            value['url'] is String &&
            value['publishableKey'] is String &&
            validate(
                  value['url'] as String,
                  value['publishableKey'] as String,
                ) ==
                null) {
          return CloudSyncConfig(
            url: value['url'] as String,
            publishableKey: value['publishableKey'] as String,
          );
        }
      } catch (_) {
        // A damaged config can be entered again in Settings.
      }
    }
    return const CloudSyncConfig(
      url: buildUrl,
      publishableKey: buildPublishableKey,
    );
  }

  Future<void> save(Directory directory) => fileIn(directory).writeAsString(
    jsonEncode({'url': url, 'publishableKey': publishableKey}),
    flush: true,
  );

  static String? validate(String url, String key) {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
      return 'Enter a valid HTTPS Supabase project URL.';
    }
    if (key.trim().isEmpty) return 'Enter the project publishable key.';
    if (key.trim().startsWith('sb_secret_')) {
      return 'Use the publishable key, never a secret key.';
    }
    return null;
  }
}
