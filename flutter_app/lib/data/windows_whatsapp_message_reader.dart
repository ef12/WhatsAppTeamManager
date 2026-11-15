import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'whatsapp_message_reader.dart';

/// Reads the cache produced by the Windows whatsapp-web.js companion.
/// The companion performs the WhatsApp Web history fetch; this adapter exposes
/// that data through the same contract used by the Android bridge.
class WindowsWhatsAppMessageReader implements WhatsAppMessageReader {
  WindowsWhatsAppMessageReader({String? dataDirectory})
    : _dataDirectory = dataDirectory ?? _defaultDataDirectory();

  final String _dataDirectory;
  String? _selectedGroupId;
  String? _selectedGroupName;
  DatabaseFactory? _databaseFactory;

  String get _databasePath => path.join(_dataDirectory, 'messages.sqlite');
  String get _selectionPath => path.join(_dataDirectory, 'selected-group.json');

  static String _defaultDataDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final userProfile =
        Platform.environment['USERPROFILE'] ?? Directory.current.path;
    return path.join(
      localAppData ?? path.join(userProfile, 'AppData', 'Local'),
      'RKAVICTeamManager',
      'whatsapp-reader',
    );
  }

  DatabaseFactory get _factory {
    if (_databaseFactory == null) {
      sqfliteFfiInit();
      _databaseFactory = databaseFactoryFfi;
    }
    return _databaseFactory!;
  }

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<void> start() async {
    if (!File(_databasePath).existsSync()) {
      throw StateError(
        'Start the Windows WhatsApp companion first, then return here to read its fetched history.',
      );
    }
    await _loadSelection();
  }

  @override
  Future<List<WhatsAppReaderGroup>> loadGroups() async {
    await _loadSelection();
    if (_selectedGroupId == null || _selectedGroupName == null) return [];
    return [
      WhatsAppReaderGroup(id: _selectedGroupId!, name: _selectedGroupName!),
    ];
  }

  Future<void> _loadSelection() async {
    final file = File(_selectionPath);
    if (!await file.exists()) {
      _selectedGroupId = null;
      _selectedGroupName = null;
      return;
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _selectedGroupId = data['id'] as String?;
    _selectedGroupName = data['name'] as String?;
  }

  @override
  Future<void> selectGroup(String groupId) async {
    await _loadSelection();
    if (groupId != _selectedGroupId) {
      throw StateError(
        'Choose the group in the Windows companion, then refresh this screen.',
      );
    }
  }

  @override
  Future<WhatsAppReaderResult> readToday() => _read('today');

  @override
  Future<WhatsAppReaderResult> readLatest() => _read('latest');

  Future<WhatsAppReaderResult> _read(String mode) async {
    await _loadSelection();
    final groupId = _selectedGroupId;
    if (groupId == null) {
      return WhatsAppReaderResult({
        'type': 'history_result',
        'mode': mode,
        'error': 'Select a group in the Windows companion first.',
        'messages': <Map<String, dynamic>>[],
      });
    }
    if (!File(_databasePath).existsSync()) {
      return WhatsAppReaderResult({
        'type': 'history_result',
        'mode': mode,
        'error': 'The Windows companion has not created its message cache yet.',
        'messages': <Map<String, dynamic>>[],
      });
    }

    final db = await _factory.openDatabase(
      _databasePath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = mode == 'latest'
          ? await db.query(
              'captured_messages',
              where: 'group_id = ?',
              whereArgs: [groupId],
              orderBy: 'sent_at DESC',
              limit: 1,
            )
          : await _todayRows(db, groupId);
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS message_count FROM captured_messages WHERE group_id = ?',
        [groupId],
      );
      final total = countRows.first['message_count'] as int? ?? 0;
      final messages = <Map<String, dynamic>>[];
      for (final row in rows) {
        messages.add(await _withDetails(db, row));
      }
      messages.sort(
        (left, right) =>
            DateTime.parse(left['timestamp'] as String)
                .compareTo(DateTime.parse(right['timestamp'] as String)),
      );
      return WhatsAppReaderResult({
        'type': 'history_result',
        'mode': mode,
        'cachedGroupMessages': total,
        'messages': mode == 'latest' && messages.isNotEmpty
            ? [messages.last]
            : messages,
        if (messages.isEmpty) 'error': 'The Windows companion has no matching messages saved for this group.',
      });
    } finally {
      await db.close();
    }
  }

  Future<List<Map<String, Object?>>> _todayRows(
    Database db,
    String groupId,
  ) async {
    final now = DateTime.now();
    final start = DateTime(
      now.year,
      now.month,
      now.day,
    ).toUtc().toIso8601String();
    final end = DateTime(
      now.year,
      now.month,
      now.day + 1,
    ).toUtc().toIso8601String();
    return db.rawQuery(
      '''
      SELECT DISTINCT message.*
      FROM captured_messages AS message
      WHERE message.group_id = ? AND (
        (message.sent_at >= ? AND message.sent_at < ?)
        OR (message.message_type = 'poll' AND EXISTS (
          SELECT 1 FROM captured_poll_votes AS vote
          WHERE vote.poll_message_id = message.message_id
            AND vote.interacted_at >= ? AND vote.interacted_at < ?
        ))
      )
      ORDER BY message.sent_at ASC
      ''',
      [groupId, start, end, start, end],
    );
  }

  Future<Map<String, dynamic>> _withDetails(
    Database db,
    Map<String, Object?> row,
  ) async {
    final id = row['message_id'] as String;
    final senderId = row['sender_id'] as String? ?? 'member';
    final isPoll = row['message_type'] == 'poll';
    final poll = isPoll && row['poll_json'] is String
        ? jsonDecode(row['poll_json'] as String) as Map<String, dynamic>
        : const <String, dynamic>{};
    final voteRows = isPoll
        ? await db.query(
            'captured_poll_votes',
            where: 'poll_message_id = ?',
            whereArgs: [id],
            orderBy: 'interacted_at ASC',
          )
        : const <Map<String, Object?>>[];
    final reactionRows = await db.query(
      'captured_reactions',
      where: 'message_id = ?',
      whereArgs: [id],
      orderBy: 'reacted_at ASC',
    );
    return {
      'id': id,
      'chat': row['group_id'],
      'senderId': senderId,
      'sender': senderId == 'me' ? 'you' : senderId,
      'timestamp': row['sent_at'],
      'kind': isPoll ? 'poll' : 'message',
      'text': isPoll ? poll['question'] ?? row['text'] : row['text'],
      if (isPoll) 'options': poll['options'] ?? const [],
      if (isPoll)
        'votes': voteRows.map((vote) {
          final selected =
              jsonDecode(vote['selected_options'] as String) as List<dynamic>;
          return {
            'voterId': vote['voter_id'],
            'voter': vote['voter_id'],
            'options': selected
                .map(
                  (option) => option is String
                      ? option
                      : (option as Map<String, dynamic>)['name'] ?? '',
                )
                .where((name) => name.toString().isNotEmpty)
                .toList(),
            'at': vote['interacted_at'],
          };
        }).toList(),
      if (reactionRows.isNotEmpty)
        'reactions': reactionRows
            .map(
              (reaction) => {
                'senderId': reaction['sender_id'],
                'sender': reaction['sender_id'],
                'emoji': reaction['emoji'],
                'at': reaction['reacted_at'],
              },
            )
            .toList(),
    };
  }

  @override
  Future<void> stop() async {}
}
