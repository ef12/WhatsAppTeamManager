import 'dart:convert';

import 'package:flutter/services.dart';

class WhatsAppReaderGroup {
  const WhatsAppReaderGroup({required this.id, required this.name});

  final String id;
  final String name;

  factory WhatsAppReaderGroup.fromJson(Map<String, dynamic> json) =>
      WhatsAppReaderGroup(
        id: json['id'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class WhatsAppReaderResult {
  const WhatsAppReaderResult(this.json);

  final Map<String, dynamic> json;

  String? get error => json['error'] as String?;
  List<Map<String, dynamic>> get messages =>
      (json['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
}

/// Shared reader contract. Each operating system supplies its own WhatsApp
/// connection and history implementation while the app consumes one result shape.
abstract interface class WhatsAppMessageReader {
  Stream<Map<String, dynamic>> get events;

  Future<void> start();
  Future<List<WhatsAppReaderGroup>> loadGroups();
  Future<void> selectGroup(String groupId);
  Future<WhatsAppReaderResult> readToday();
  Future<WhatsAppReaderResult> readLatest();
  Future<void> stop();
}

abstract interface class WhatsAppReaderAuthorization {
  Future<bool> hasNotificationAccess();
  Future<void> openNotificationAccessSettings();
}

class AndroidWhatsAppMessageReader
    implements WhatsAppMessageReader, WhatsAppReaderAuthorization {
  static const _methods = MethodChannel(
    'nl.rkavic.manager/android_whatsapp_spike',
  );
  static const _eventChannel = EventChannel(
    'nl.rkavic.manager/android_whatsapp_events',
  );

  @override
  Stream<Map<String, dynamic>> get events =>
      _eventChannel.receiveBroadcastStream().map(
        (value) => value is String
            ? jsonDecode(value) as Map<String, dynamic>
            : Map<String, dynamic>.from(value as Map),
      );

  @override
  Future<void> start() async {
    await _methods.invokeMethod<bool>('start');
  }

  @override
  Future<bool> hasNotificationAccess() async =>
      await _methods.invokeMethod<bool>('hasNotificationAccess') ?? false;

  @override
  Future<void> openNotificationAccessSettings() async {
    await _methods.invokeMethod<bool>('openNotificationAccess');
  }

  @override
  Future<List<WhatsAppReaderGroup>> loadGroups() async {
    final result = await _methods.invokeMethod<String>('groups');
    final decoded = jsonDecode(result ?? '[]') as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(WhatsAppReaderGroup.fromJson)
        .toList();
  }

  @override
  Future<void> selectGroup(String groupId) async {
    await _methods.invokeMethod<bool>('selectGroup', {'id': groupId});
  }

  @override
  Future<WhatsAppReaderResult> readToday() => _read('readToday');

  @override
  Future<WhatsAppReaderResult> readLatest() => _read('readLatest');

  Future<WhatsAppReaderResult> _read(String method) async {
    final value = await _methods.invokeMethod<String>(method);
    return WhatsAppReaderResult(
      jsonDecode(value ?? '{}') as Map<String, dynamic>,
    );
  }

  @override
  Future<void> stop() async {
    await _methods.invokeMethod<bool>('stop');
  }
}
