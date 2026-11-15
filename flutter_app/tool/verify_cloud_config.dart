import 'dart:io';

import 'package:rkavic_manager/data/cloud_sync_config.dart';

Future<void> main() async {
  assert(CloudSyncConfig.validate('http://example.com', 'key') != null);
  assert(CloudSyncConfig.validate('https://example.com', '') != null);
  assert(
    CloudSyncConfig.validate('https://example.com', 'sb_secret_bad') != null,
  );
  assert(
    CloudSyncConfig.validate(
          'https://example.supabase.co',
          'sb_publishable_test',
        ) ==
        null,
  );

  final directory = await Directory.systemTemp.createTemp(
    'rkavic-cloud-config-',
  );
  try {
    final config = CloudSyncConfig(
      url: 'https://example.supabase.co',
      publishableKey: 'sb_publishable_test',
    );
    await config.save(directory);
    final restored = await CloudSyncConfig.load(directory);
    assert(restored.url == config.url);
    assert(restored.publishableKey == config.publishableKey);
  } finally {
    await CloudSyncConfig.fileIn(directory).delete();
    await directory.delete();
  }
}
