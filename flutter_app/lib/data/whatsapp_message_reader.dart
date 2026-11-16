import 'dart:convert';

import 'package:flutter/services.dart';

class WhatsAppReaderGroup {
  const WhatsAppReaderGroup({
    required this.id,
    required this.name,
    this.selected = false,
  });

  final String id;
  final String name;
  final bool selected;

  factory WhatsAppReaderGroup.fromJson(Map<String, dynamic> json) =>
      WhatsAppReaderGroup(
        id: json['id'] as String,
        name: json['name'] as String,
        selected: json['selected'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (selected) 'selected': true,
  };
}

class WhatsAppReaderResult {
  const WhatsAppReaderResult(this.json);

  final Map<String, dynamic> json;

  String? get error => json['error'] as String?;
  List<Map<String, dynamic>> get messages =>
      (json['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  List<WhatsAppPollSnapshot> get polls => messages
      .where((message) => message['kind'] == 'poll')
      .map(WhatsAppPollSnapshot.fromJson)
      .toList();
}

class WhatsAppPollVote {
  const WhatsAppPollVote({
    required this.voterId,
    required this.voter,
    required this.options,
    required this.updatedAt,
  });

  final String voterId;
  final String voter;
  final List<String> options;
  final DateTime? updatedAt;

  factory WhatsAppPollVote.fromJson(Map<String, dynamic> json) =>
      WhatsAppPollVote(
        voterId: json['voterId']?.toString() ?? '',
        voter: json['voter']?.toString() ?? 'Unknown participant',
        options: _optionNames(json['options']),
        updatedAt: DateTime.tryParse(
          (json['at'] ?? json['interactedAt'])?.toString() ?? '',
        ),
      );
}

class WhatsAppPollSnapshot {
  const WhatsAppPollSnapshot({
    required this.id,
    required this.groupId,
    required this.question,
    required this.createdAt,
    required this.options,
    required this.votes,
    this.allowMultipleAnswers,
  });

  final String id;
  final String groupId;
  final String question;
  final DateTime? createdAt;
  final List<String> options;
  final List<WhatsAppPollVote> votes;
  final bool? allowMultipleAnswers;

  factory WhatsAppPollSnapshot.fromJson(Map<String, dynamic> json) =>
      WhatsAppPollSnapshot(
        id: json['id']?.toString() ?? '',
        groupId: (json['chat'] ?? json['groupId'])?.toString() ?? '',
        question: (json['text'] ?? json['question'])?.toString() ?? 'Poll',
        createdAt: DateTime.tryParse(
          (json['timestamp'] ?? json['createdAt'])?.toString() ?? '',
        ),
        options: _optionNames(json['options']),
        votes: (json['votes'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(WhatsAppPollVote.fromJson)
            .toList(),
        allowMultipleAnswers: json['allowMultipleAnswers'] as bool?,
      );
}

List<String> _optionNames(Object? raw) => (raw as List<dynamic>? ?? const [])
    .map((option) {
      if (option is String) return option.trim();
      if (option is Map<String, dynamic>)
        return option['name']?.toString().trim() ?? '';
      return '';
    })
    .where((name) => name.isNotEmpty)
    .toList();

/// Shared reader contract. Each operating system supplies its own WhatsApp
/// connection and history implementation while the app consumes one result shape.
abstract interface class WhatsAppMessageReader {
  Stream<Map<String, dynamic>> get events;

  Future<void> start();
  Future<List<WhatsAppReaderGroup>> loadGroups();
  Future<List<WhatsAppPollSnapshot>> availablePolls();
  Future<void> selectGroup(String groupId);
  Future<WhatsAppReaderResult> readToday();
  Future<WhatsAppReaderResult> readLatest();
  Future<void> stop();
}

abstract interface class WhatsAppReaderAuthorization {
  Future<bool> hasNotificationAccess();
  Future<void> openNotificationAccessSettings();
  Future<bool> hasCaptureConsent();
  Future<void> setCaptureConsent(bool allowed);
}

abstract interface class WhatsAppStructuredPollReader {
  Future<void> startPollReader();
  Future<String?> pairPollReader(String phoneNumber);
  Future<List<WhatsAppReaderGroup>> loadPollGroups();
  Future<void> selectPollGroup(String groupId);
  Future<void> stopPollReader();
}

class AndroidWhatsAppMessageReader
    implements
        WhatsAppMessageReader,
        WhatsAppReaderAuthorization,
        WhatsAppStructuredPollReader {
  static const _methods = MethodChannel(
    'nl.rkavic.manager/android_whatsapp_spike',
  );
  static const _eventChannel = EventChannel(
    'nl.rkavic.manager/android_whatsapp_events',
  );
  late final Stream<Map<String, dynamic>> _events = _eventChannel
      .receiveBroadcastStream()
      .map(
        (value) => value is String
            ? jsonDecode(value) as Map<String, dynamic>
            : Map<String, dynamic>.from(value as Map),
      );

  @override
  Stream<Map<String, dynamic>> get events => _events;

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
  Future<bool> hasCaptureConsent() async =>
      await _methods.invokeMethod<bool>('hasCaptureConsent') ?? false;

  @override
  Future<void> setCaptureConsent(bool allowed) async {
    await _methods.invokeMethod<bool>('setCaptureConsent', {
      'allowed': allowed,
    });
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
  Future<List<WhatsAppPollSnapshot>> availablePolls() async {
    final result = await _methods.invokeMethod<String>('polls');
    final decoded =
        jsonDecode(result ?? '{"messages":[]}') as Map<String, dynamic>;
    return (decoded['messages'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(WhatsAppPollSnapshot.fromJson)
        .toList();
  }

  @override
  Future<void> startPollReader() async {
    await _methods.invokeMethod<bool>('startPollReader');
  }

  @override
  Future<String?> pairPollReader(String phoneNumber) async {
    final response = await _methods.invokeMethod<String>('pairPollReader', {
      'phone': phoneNumber,
    });
    final decoded = jsonDecode(response ?? '{}') as Map<String, dynamic>;
    return decoded['code'] as String? ?? decoded['error'] as String?;
  }

  @override
  Future<List<WhatsAppReaderGroup>> loadPollGroups() async {
    final result = await _methods.invokeMethod<String>('pollGroups');
    final decoded = jsonDecode(result ?? '[]') as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(WhatsAppReaderGroup.fromJson)
        .toList();
  }

  @override
  Future<void> selectPollGroup(String groupId) async {
    await _methods.invokeMethod<bool>('selectPollGroup', {'id': groupId});
  }

  @override
  Future<void> stopPollReader() async {
    await _methods.invokeMethod<bool>('stopPollReader');
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
