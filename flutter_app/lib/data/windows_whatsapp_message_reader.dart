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
  bool _selectionPending = false;
  DatabaseFactory? _databaseFactory;
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();
  Process? _companionProcess;
  Directory? _companionDirectory;

  String get _databasePath => path.join(_dataDirectory, 'messages.sqlite');
  String get _selectionPath => path.join(_dataDirectory, 'selected-group.json');
  String get _requestPath =>
      path.join(_dataDirectory, 'selection-request.json');
  String get _groupsPath => path.join(_dataDirectory, 'groups.json');

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
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  @override
  Future<void> start() async {
    if (_companionProcess != null) return;
    final companion = _findCompanionDirectory();
    if (companion == null) {
      throw StateError(
        'The WhatsApp reader files are missing. Reinstall the app with its companion files.',
      );
    }
    _companionDirectory = companion;
    final process = await Process.start(
      'node',
      ['src/reader.js'],
      workingDirectory: companion.path,
      environment: {
        ...Platform.environment,
        'RKAVIC_APP_MODE': '1',
        'RKAVIC_CAPTURE_CONSENT': 'YES',
      },
    );
    _companionProcess = process;
    _forwardOutput(process.stdout);
    _forwardOutput(process.stderr, isError: true);
    process.exitCode.then((code) {
      if (identical(_companionProcess, process)) _companionProcess = null;
      _eventController.add({'type': 'companion_exit', 'code': code});
    });
    await _loadSelection();
  }

  Directory? _findCompanionDirectory() {
    final configured = Platform.environment['RKAVIC_COMPANION_DIR'];
    if (configured != null &&
        File(path.join(configured, 'src', 'reader.js')).existsSync()) {
      return Directory(configured);
    }
    var directory = Directory(path.dirname(Platform.resolvedExecutable));
    for (var depth = 0; depth < 10; depth++) {
      final candidate = Directory(path.join(directory.path, 'companion'));
      if (File(path.join(candidate.path, 'src', 'reader.js')).existsSync()) {
        return candidate;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
    return null;
  }

  void _forwardOutput(Stream<List<int>> output, {bool isError = false}) {
    output.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      const prefix = 'RKAVIC_EVENT:';
      if (line.startsWith(prefix)) {
        try {
          _eventController.add(
            jsonDecode(line.substring(prefix.length)) as Map<String, dynamic>,
          );
          return;
        } catch (_) {}
      }
      _eventController.add({
        'type': isError ? 'companion_error' : 'companion_log',
        'text': line,
      });
    });
  }

  @override
  Future<List<WhatsAppReaderGroup>> loadGroups() async {
    await _loadSelection();
    final groupsFile = File(_groupsPath);
    if (!await groupsFile.exists()) return [];
    final values = jsonDecode(await groupsFile.readAsString()) as List<dynamic>;
    return values
        .whereType<Map<String, dynamic>>()
        .map(
          (value) => WhatsAppReaderGroup(
            id: value['id'] as String,
            name: value['name'] as String,
            selected: value['id'] == _selectedGroupId,
          ),
        )
        .toList();
  }

  @override
  Future<List<WhatsAppPollSnapshot>> availablePolls() async {
    await _loadSelection();
    final groupId = _selectedGroupId;
    if (groupId == null || !File(_databasePath).existsSync()) return const [];
    final db = await _factory.openDatabase(
      _databasePath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = await db.query(
        'captured_messages',
        where: 'group_id = ? AND message_type = ?',
        whereArgs: [groupId, 'poll'],
        orderBy: 'sent_at DESC',
        limit: 100,
      );
      final polls = <WhatsAppPollSnapshot>[];
      for (final row in rows) {
        polls.add(WhatsAppPollSnapshot.fromJson(await _withDetails(db, row)));
      }
      return polls;
    } finally {
      await db.close();
    }
  }

  Future<void> _loadSelection() async {
    final file = File(_selectionPath);
    if (!await file.exists()) {
      if (!_selectionPending) {
        _selectedGroupId = null;
        _selectedGroupName = null;
      }
      return;
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final diskId = data['id'] as String?;
    if (_selectionPending && diskId == _selectedGroupId) {
      _selectionPending = false;
    } else if (!_selectionPending) {
      _selectedGroupId = diskId;
      _selectedGroupName = data['name'] as String?;
    }
  }

  @override
  Future<void> selectGroup(String groupId) async {
    final groups = await loadGroups();
    final group = groups
        .where((candidate) => candidate.id == groupId)
        .firstOrNull;
    if (group == null)
      throw StateError(
        'That group is not available from the connected WhatsApp account.',
      );
    final file = File(_requestPath);
    final temporary = File('$_requestPath.tmp');
    await temporary.writeAsString(
      jsonEncode({'id': group.id, 'name': group.name}),
    );
    await temporary.rename(file.path);
    _selectedGroupId = group.id;
    _selectedGroupName = group.name;
    _selectionPending = true;
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
    final savedSenderName = row['sender_name'] as String?;
    final senderName = savedSenderName?.trim().isNotEmpty == true
        ? savedSenderName!.trim()
        : senderId.endsWith('@lid')
        ? 'Unknown participant'
        : senderId;
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
      'sender': senderId == 'me' ? 'you' : senderName,
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
            'voter': vote['voter_name'] as String? ?? vote['voter_id'],
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
                'sender':
                    reaction['sender_name'] as String? ?? reaction['sender_id'],
                'emoji': reaction['emoji'],
                'at': reaction['reacted_at'],
              },
            )
            .toList(),
    };
  }

  @override
  Future<void> stop() async {
    final process = _companionProcess;
    _companionProcess = null;
    process?.kill(ProcessSignal.sigterm);
  }
}
