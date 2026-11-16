import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as desktop;

import 'team_backup.dart';
import 'whatsapp_message_reader.dart';

class Player {
  const Player(this.id, this.name, this.parent);

  final int id;
  final String name;
  final String parent;

  factory Player.fromRow(Map<String, Object?> row) =>
      Player(row['id'] as int, row['name'] as String, row['parent'] as String);
}

List<String> _nameTokens(String value) => RegExp(
  r'[\p{L}\p{N}]+',
  unicode: true,
).allMatches(value.toLowerCase()).map((match) => match.group(0)!).toList();

String _nameKey(String value) => _nameTokens(value).join(' ');

String _unorderedNameKey(String value) {
  final tokens = _nameTokens(value)..sort();
  return tokens.join(' ');
}

/// Returns a status only when the answer starts with an unambiguous response.
int? inferredPollStatus(String answer) {
  final words = _nameTokens(answer);
  if (words.isEmpty) return null;
  switch (words.first) {
    case 'yes':
    case 'ja':
    case 'present':
    case 'coming':
    case 'aanwezig':
      return 1;
    case 'no':
    case 'nee':
    case 'absent':
    case 'afwezig':
      return 2;
    case 'maybe':
    case 'perhaps':
    case 'misschien':
      return 3;
  }
  return null;
}

/// Matches a voter to one roster family, including all children of one parent.
/// A surname is used only if it identifies one family in the roster.
Set<int> inferredVoterPlayers(String voterName, List<Player> roster) {
  final tokens = _nameTokens(voterName);
  if (tokens.length < 2 ||
      voterName.contains('@') ||
      tokens.every((token) => RegExp(r'^\d+$').hasMatch(token)) ||
      _nameKey(voterName) == 'unknown participant') {
    return <int>{};
  }
  Set<int> oneFamily(Iterable<Player> candidates) {
    final found = candidates.toList();
    if (found.isEmpty) return <int>{};
    final families = found
        .map(
          (player) => _nameKey(player.parent).isEmpty
              ? 'player:${player.id}'
              : _nameKey(player.parent),
        )
        .toSet();
    return families.length == 1
        ? {for (final player in found) player.id}
        : <int>{};
  }

  final name = _nameKey(voterName);
  final unordered = _unorderedNameKey(voterName);
  final stages = <Iterable<Player>>[
    roster.where((player) => _nameKey(player.parent) == name),
    roster.where((player) => _nameKey(player.name) == name),
    roster.where((player) => _unorderedNameKey(player.parent) == unordered),
    roster.where((player) => _unorderedNameKey(player.name) == unordered),
    roster.where((player) {
      final playerWords = _nameTokens(player.name);
      final parentWords = _nameTokens(player.parent);
      final surname = tokens.last;
      return (playerWords.isNotEmpty && playerWords.last == surname) ||
          (parentWords.isNotEmpty && parentWords.last == surname);
    }),
  ];
  for (final candidates in stages) {
    final found = candidates.toList();
    if (found.isNotEmpty) return oneFamily(found);
  }
  return <int>{};
}

class TeamMatch {
  const TeamMatch(
    this.id,
    this.title,
    this.kickoff,
    this.meet,
    this.location,
    this.fieldNumber,
    this.isHome,
    this.deadline,
    this.rkavicScore,
    this.opponentScore,
    this.done,
  );

  final int id;
  final String title;
  final String kickoff;
  final String meet;
  final String location;
  final String fieldNumber;
  final bool isHome;
  final String deadline;
  final int? rkavicScore;
  final int? opponentScore;
  final bool done;

  String get venue => [
    if (location.isNotEmpty) location,
    if (fieldNumber.isNotEmpty) 'Field $fieldNumber',
  ].join(' • ');

  Uri? get mapsUri => location.trim().isEmpty
      ? null
      : Uri.https('www.google.com', '/maps/search/', {
          'api': '1',
          'query': location.trim(),
        });

  String get result => rkavicScore == null || opponentScore == null
      ? 'Result not entered'
      : 'RKAVIC $rkavicScore – $opponentScore Opponent';

  factory TeamMatch.fromRow(Map<String, Object?> row) => TeamMatch(
    row['id'] as int,
    row['title'] as String,
    row['date'] as String,
    row['meet'] as String,
    row['location'] as String,
    row['field_number'] as String,
    row['is_home'] == 1,
    row['deadline'] as String,
    row['rkavic_score'] as int?,
    row['opponent_score'] as int?,
    row['done'] == 1,
  );
}

class AttendancePollLink {
  const AttendancePollLink({
    required this.matchId,
    required this.groupId,
    required this.pollId,
    required this.question,
    required this.options,
    required this.linkedAt,
  });

  final int matchId;
  final String groupId;
  final String pollId;
  final String question;
  final List<String> options;
  final DateTime linkedAt;

  factory AttendancePollLink.fromRow(Map<String, Object?> row) =>
      AttendancePollLink(
        matchId: row['match_id'] as int,
        groupId: row['group_id'] as String,
        pollId: row['poll_id'] as String,
        question: row['question'] as String,
        options: (jsonDecode(row['options_json'] as String) as List<dynamic>)
            .whereType<String>()
            .toList(),
        linkedAt: DateTime.parse(row['linked_at'] as String),
      );
}

class Duty {
  const Duty(
    this.id,
    this.matchId,
    this.templateId,
    this.title,
    this.description,
    this.playerId,
    this.parentName,
    this.done,
  );

  final int id;
  final int matchId;
  final int? templateId;
  final String title;
  final String description;
  final int? playerId;
  final String? parentName;
  final bool done;

  factory Duty.fromRow(Map<String, Object?> row) => Duty(
    row['id'] as int,
    row['match_id'] as int,
    row['template_id'] as int?,
    row['title'] as String,
    row['description'] as String,
    row['player_id'] as int?,
    row['parent_name'] as String?,
    row['done'] == 1,
  );
}

class DutyTemplate {
  const DutyTemplate(this.id, this.title, this.description);

  final int id;
  final String title;
  final String description;

  factory DutyTemplate.fromRow(Map<String, Object?> row) => DutyTemplate(
    row['id'] as int,
    row['title'] as String,
    row['description'] as String,
  );
}

class ParticipationSummary {
  const ParticipationSummary({
    required this.playerId,
    required this.present,
    required this.absent,
    required this.noResponse,
  });

  final int playerId;
  final int present;
  final int absent;
  final int noResponse;

  int get total => present + absent + noResponse;

  double get rate => total == 0 ? 0 : present / total;
}

class ParentDutySummary {
  const ParentDutySummary({
    required this.name,
    required this.children,
    required this.assigned,
    required this.done,
    required this.relieved,
  });

  final String name;
  final List<String> children;
  final int assigned;
  final int done;
  final bool relieved;
}

class LocalSyncState {
  const LocalSyncState({
    required this.localRevision,
    required this.lastSyncedRevision,
    required this.remoteRevision,
    required this.syncUserId,
    required this.lastSyncedAt,
    required this.baselinePayload,
  });

  final int localRevision;
  final int? lastSyncedRevision;
  final int remoteRevision;
  final String? syncUserId;
  final DateTime? lastSyncedAt;
  final String? baselinePayload;
}

class LocalSyncConflictException implements Exception {
  const LocalSyncConflictException();
}

class TeamStore {
  TeamStore._(this._db);

  final Database _db;
  static const _ignoredVoterPlayerId = 0;
  static final Random _idRandom = Random.secure();
  static int _newId() =>
      ((_idRandom.nextInt(1 << 26) << 26) | _idRandom.nextInt(1 << 26)) + 1;

  static Future<TeamStore> open() async {
    late final DatabaseFactory factory;
    late final String dbPath;
    if (Platform.isWindows) {
      desktop.sqfliteFfiInit();
      factory = desktop.databaseFactoryFfi;
      final directory = await getApplicationSupportDirectory();
      dbPath = path.join(directory.path, 'team.db');
    } else {
      factory = mobile.databaseFactory;
      // This is the Android SQLiteOpenHelper location used by V1.
      dbPath = path.join(await mobile.getDatabasesPath(), 'team.db');
    }

    return openAt(dbPath, factory);
  }

  static Future<TeamStore> openAt(
    String dbPath,
    DatabaseFactory factory,
  ) async {
    final db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 9,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE players(id INTEGER PRIMARY KEY,name TEXT NOT NULL,'
            'parent TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE matches(id INTEGER PRIMARY KEY,title TEXT NOT NULL,'
            'date TEXT NOT NULL,meet TEXT NOT NULL,location TEXT NOT NULL,'
            'field_number TEXT NOT NULL DEFAULT \'\','
            'is_home INTEGER NOT NULL DEFAULT 0,deadline TEXT NOT NULL,'
            'rkavic_score INTEGER,opponent_score INTEGER,'
            'done INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE attendance(match_id INTEGER NOT NULL,'
            'player_id INTEGER NOT NULL,status INTEGER NOT NULL,'
            'PRIMARY KEY(match_id,player_id))',
          );
          await db.execute(
            'CREATE TABLE duties(id INTEGER PRIMARY KEY,match_id INTEGER NOT NULL,'
            'template_id INTEGER,title TEXT NOT NULL,description TEXT NOT NULL DEFAULT \'\','
            'player_id INTEGER,parent_name TEXT,done INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE duty_templates(id INTEGER PRIMARY KEY,'
            'title TEXT NOT NULL,description TEXT NOT NULL DEFAULT \'\')',
          );
          await db.execute(
            'CREATE TABLE parent_duty_exemptions(parent_name TEXT PRIMARY KEY)',
          );
          await _createWhatsAppPollLinks(db);
          await _createWhatsAppAttendance(db);
          await _createSyncTracking(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE matches ADD COLUMN rkavic_score INTEGER',
            );
            await db.execute(
              'ALTER TABLE matches ADD COLUMN opponent_score INTEGER',
            );
            await db.execute(
              'ALTER TABLE matches ADD COLUMN done INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              "ALTER TABLE matches ADD COLUMN field_number TEXT NOT NULL DEFAULT ''",
            );
          }
          if (oldVersion < 4) {
            final matchColumns = await db.rawQuery(
              'PRAGMA table_info(matches)',
            );
            if (!matchColumns.any((column) => column['name'] == 'is_home')) {
              await db.execute(
                'ALTER TABLE matches ADD COLUMN is_home INTEGER NOT NULL DEFAULT 0',
              );
            }
            final dutyTables = await db.query(
              'sqlite_master',
              columns: ['name'],
              where: 'type=? AND name=?',
              whereArgs: ['table', 'duties'],
            );
            if (dutyTables.isEmpty) {
              await db.execute(
                'CREATE TABLE duties(id INTEGER PRIMARY KEY,'
                'match_id INTEGER NOT NULL,template_id INTEGER,'
                'title TEXT NOT NULL,description TEXT NOT NULL DEFAULT \'\','
                'player_id INTEGER,done INTEGER NOT NULL DEFAULT 0)',
              );
            } else {
              final dutyColumns = await db.rawQuery(
                'PRAGMA table_info(duties)',
              );
              if (!dutyColumns.any(
                (column) => column['name'] == 'template_id',
              )) {
                await db.execute(
                  'ALTER TABLE duties ADD COLUMN template_id INTEGER',
                );
              }
              if (!dutyColumns.any(
                (column) => column['name'] == 'description',
              )) {
                await db.execute(
                  "ALTER TABLE duties ADD COLUMN description TEXT NOT NULL DEFAULT ''",
                );
              }
            }
            await db.execute(
              'CREATE TABLE IF NOT EXISTS duty_templates(id INTEGER PRIMARY KEY,'
              'title TEXT NOT NULL,description TEXT NOT NULL DEFAULT \'\')',
            );
          }
          if (oldVersion < 5) {
            final dutyColumns = await db.rawQuery('PRAGMA table_info(duties)');
            final hasParentName = dutyColumns.any(
              (column) => column['name'] == 'parent_name',
            );
            if (!hasParentName) {
              await db.execute(
                'ALTER TABLE duties ADD COLUMN parent_name TEXT',
              );
            }
            await db.execute(
              'CREATE TABLE IF NOT EXISTS parent_duty_exemptions('
              'parent_name TEXT PRIMARY KEY)',
            );
            final playerTables = await db.query(
              'sqlite_master',
              columns: ['name'],
              where: 'type=? AND name=?',
              whereArgs: ['table', 'players'],
            );
            if (playerTables.isNotEmpty) {
              await db.execute(
                'UPDATE duties SET parent_name=('
                'SELECT parent FROM players WHERE players.id=duties.player_id'
                ') WHERE parent_name IS NULL AND player_id IS NOT NULL',
              );
            }
          }
          if (oldVersion < 6) {
            await _createSyncTracking(db);
          }
          if (oldVersion == 6) {
            await db.execute(
              'ALTER TABLE app_sync_state ADD COLUMN baseline_payload TEXT',
            );
          }
          if (oldVersion < 8) await _createWhatsAppPollLinks(db);
          if (oldVersion < 9) await _createWhatsAppAttendance(db);
        },
      ),
    );
    return TeamStore._(db);
  }

  Future<void> close() => _db.close();

  Future<LocalSyncState> localSyncState() async {
    final rows = await _db.query('app_sync_state', where: 'id=1', limit: 1);
    final row = rows.single;
    return LocalSyncState(
      localRevision: row['local_revision'] as int,
      lastSyncedRevision: row['last_synced_revision'] as int?,
      remoteRevision: row['remote_revision'] as int,
      syncUserId: row['sync_user_id'] as String?,
      lastSyncedAt: DateTime.tryParse(row['last_synced_at'] as String? ?? ''),
      baselinePayload: row['baseline_payload'] as String?,
    );
  }

  Future<void> prepareSyncForUser(String userId) =>
      _db.transaction((txn) async {
        final rows = await txn.query(
          'app_sync_state',
          columns: ['sync_user_id'],
          where: 'id=1',
          limit: 1,
        );
        if (rows.single['sync_user_id'] == userId) return;
        await txn.update('app_sync_state', {
          'sync_user_id': userId,
          'last_synced_revision': null,
          'remote_revision': 0,
          'last_synced_at': null,
          'baseline_payload': null,
        }, where: 'id=1');
      });

  Future<bool> hasTeamData() async {
    for (final table in [
      'players',
      'matches',
      'attendance',
      'duties',
      'duty_templates',
      'parent_duty_exemptions',
    ]) {
      final rows = await _db.rawQuery('SELECT 1 FROM $table LIMIT 1');
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  Future<void> markSyncState({
    required int lastSyncedRevision,
    required int remoteRevision,
    required String baselinePayload,
  }) => _db.transaction((txn) async {
    // Preserve the exported revision as the sync baseline. If the user edited
    // while the upload was in flight, the newer local revision stays dirty.
    await txn.update('app_sync_state', {
      'last_synced_revision': lastSyncedRevision,
      'remote_revision': remoteRevision,
      'last_synced_at': DateTime.now().toUtc().toIso8601String(),
      'baseline_payload': baselinePayload,
    }, where: 'id=1');
  });

  Future<void> restoreCloudSnapshot({
    required TeamBackup backup,
    required int expectedLocalRevision,
    required int remoteRevision,
    required String baselinePayload,
  }) => _db.transaction((txn) async {
    final state = await txn.query(
      'app_sync_state',
      columns: ['local_revision'],
      where: 'id=1',
      limit: 1,
    );
    if (state.single['local_revision'] != expectedLocalRevision) {
      throw const LocalSyncConflictException();
    }
    await _replaceWithBackup(txn, backup);
    final updated = await txn.query(
      'app_sync_state',
      columns: ['local_revision'],
      where: 'id=1',
      limit: 1,
    );
    await txn.update('app_sync_state', {
      'last_synced_revision': updated.single['local_revision'],
      'remote_revision': remoteRevision,
      'last_synced_at': DateTime.now().toUtc().toIso8601String(),
      'baseline_payload': baselinePayload,
    }, where: 'id=1');
  });

  Future<LocalSyncState> stageMergedSnapshot({
    required TeamBackup backup,
    required int expectedLocalRevision,
    required int remoteRevision,
    required String remotePayload,
  }) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'app_sync_state',
        columns: ['local_revision'],
        where: 'id=1',
      );
      if (rows.single['local_revision'] != expectedLocalRevision) {
        throw const LocalSyncConflictException();
      }
      await _replaceWithBackup(txn, backup);
      await txn.update('app_sync_state', {
        'last_synced_revision': expectedLocalRevision,
        'remote_revision': remoteRevision,
        'baseline_payload': remotePayload,
      }, where: 'id=1');
    });
    return localSyncState();
  }

  static Future<void> _createSyncTracking(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE app_sync_state('
      'id INTEGER PRIMARY KEY CHECK(id=1),'
      'local_revision INTEGER NOT NULL DEFAULT 0,'
      'last_synced_revision INTEGER,'
      'remote_revision INTEGER NOT NULL DEFAULT 0,'
      'sync_user_id TEXT,last_synced_at TEXT,baseline_payload TEXT)',
    );
    await db.insert('app_sync_state', {'id': 1});
    for (final table in [
      'players',
      'matches',
      'attendance',
      'duties',
      'duty_templates',
      'parent_duty_exemptions',
    ]) {
      for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
        final name = 'sync_${table}_${event.toLowerCase()}';
        await db.execute(
          'CREATE TRIGGER $name AFTER $event ON $table BEGIN '
          'UPDATE app_sync_state SET local_revision=local_revision+1 WHERE id=1; '
          'END',
        );
      }
    }
  }

  static Future<void> _createWhatsAppPollLinks(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS whatsapp_attendance_polls('
      'match_id INTEGER PRIMARY KEY,group_id TEXT NOT NULL,poll_id TEXT NOT NULL,'
      'question TEXT NOT NULL,options_json TEXT NOT NULL,linked_at TEXT NOT NULL,'
      'UNIQUE(group_id,poll_id))',
    );
  }

  static Future<void> _createWhatsAppAttendance(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS whatsapp_poll_options('
      'match_id INTEGER NOT NULL, option_name TEXT NOT NULL, status INTEGER NOT NULL, '
      'PRIMARY KEY(match_id, option_name))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS whatsapp_player_mappings('
      'group_id TEXT NOT NULL, voter_id TEXT NOT NULL, player_id INTEGER NOT NULL, '
      'PRIMARY KEY(group_id, voter_id, player_id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS whatsapp_attendance_state('
      'match_id INTEGER NOT NULL, player_id INTEGER NOT NULL, manual_override INTEGER NOT NULL DEFAULT 0, '
      'poll_id TEXT, voter_id TEXT, vote_at TEXT, last_status INTEGER, '
      'PRIMARY KEY(match_id, player_id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS whatsapp_attendance_audit('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, match_id INTEGER NOT NULL, player_id INTEGER NOT NULL, '
      'poll_id TEXT NOT NULL, voter_id TEXT NOT NULL, old_status INTEGER NOT NULL, '
      'new_status INTEGER NOT NULL, vote_at TEXT NOT NULL)',
    );
  }

  Future<TeamBackup> exportBackup() => _db.transaction(
    (txn) async => TeamBackup.capture(
      players: await txn.query('players', orderBy: 'id'),
      matches: await txn.query('matches', orderBy: 'id'),
      attendance: await txn.query('attendance', orderBy: 'match_id, player_id'),
      duties: await txn.query('duties', orderBy: 'id'),
      dutyTemplates: await txn.query('duty_templates', orderBy: 'id'),
      parentDutyExemptions: await txn.query(
        'parent_duty_exemptions',
        orderBy: 'parent_name COLLATE NOCASE',
      ),
    ),
  );

  Future<void> replaceWithBackup(TeamBackup backup) =>
      _db.transaction((txn) => _replaceWithBackup(txn, backup));

  Future<void> _replaceWithBackup(
    DatabaseExecutor txn,
    TeamBackup backup,
  ) async {
    for (final table in [
      'attendance',
      'duties',
      'duty_templates',
      'parent_duty_exemptions',
      'matches',
      'players',
    ]) {
      await txn.delete(table);
    }
    for (final row in backup.players) {
      await txn.insert('players', row);
    }
    for (final row in backup.matches) {
      await txn.insert('matches', row);
    }
    for (final row in backup.attendance) {
      await txn.insert('attendance', row);
    }
    for (final row in backup.duties) {
      await txn.insert('duties', row);
    }
    for (final row in backup.dutyTemplates) {
      await txn.insert('duty_templates', row);
    }
    for (final row in backup.parentDutyExemptions) {
      await txn.insert('parent_duty_exemptions', row);
    }
    await txn.delete(
      'whatsapp_attendance_polls',
      where: 'match_id NOT IN (SELECT id FROM matches)',
    );
  }

  Future<List<Player>> players() async => (await _db.query(
    'players',
    orderBy: 'name COLLATE NOCASE, id',
  )).map(Player.fromRow).toList();

  Future<int> addPlayer(String name, String parent) =>
      _db.insert('players', {'id': _newId(), 'name': name, 'parent': parent});

  Future<void> updatePlayer(int id, String name, String parent) async {
    await _db.update(
      'players',
      {'name': name, 'parent': parent},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlayer(int id) => _db.transaction((txn) async {
    final playerRows = await txn.query(
      'players',
      columns: ['parent'],
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );
    final parent = playerRows.isEmpty
        ? ''
        : (playerRows.first['parent'] as String).trim();
    await txn.delete('players', where: 'id=?', whereArgs: [id]);
    await txn.delete('attendance', where: 'player_id=?', whereArgs: [id]);
    await txn.delete(
      'whatsapp_player_mappings',
      where: 'player_id=?',
      whereArgs: [id],
    );
    await txn.delete(
      'whatsapp_attendance_state',
      where: 'player_id=?',
      whereArgs: [id],
    );
    await txn.rawUpdate('UPDATE duties SET player_id=NULL WHERE player_id=?', [
      id,
    ]);
    if (parent.isNotEmpty) {
      final remaining = await txn.query(
        'players',
        columns: ['id'],
        where: 'parent=?',
        whereArgs: [parent],
        limit: 1,
      );
      if (remaining.isEmpty) {
        await txn.delete(
          'parent_duty_exemptions',
          where: 'parent_name=?',
          whereArgs: [parent],
        );
      }
    }
  });

  Future<List<TeamMatch>> matches() async => (await _db.query(
    'matches',
    orderBy: 'date, id',
  )).map(TeamMatch.fromRow).toList();

  Future<TeamMatch?> match(int id) async {
    final rows = await _db.query('matches', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty ? null : TeamMatch.fromRow(rows.first);
  }

  Future<int> addMatch({
    required String title,
    required String kickoff,
    required String meet,
    required String location,
    required String fieldNumber,
    required bool isHome,
    required String deadline,
  }) => _db.transaction((txn) async {
    final matchId = await txn.insert('matches', {
      'id': _newId(),
      'title': title,
      'date': kickoff,
      'meet': meet,
      'location': location,
      'field_number': fieldNumber,
      'is_home': isHome ? 1 : 0,
      'deadline': deadline,
    });
    if (isHome) {
      await _addTemplateDuties(txn, matchId);
    }
    return matchId;
  });

  Future<void> updateMatch(
    int id, {
    required String title,
    required String kickoff,
    required String meet,
    required String location,
    required String fieldNumber,
    required bool isHome,
    required String deadline,
  }) => _db.transaction((txn) async {
    await txn.update(
      'matches',
      {
        'title': title,
        'date': kickoff,
        'meet': meet,
        'location': location,
        'field_number': fieldNumber,
        'is_home': isHome ? 1 : 0,
        'deadline': deadline,
      },
      where: 'id=?',
      whereArgs: [id],
    );
    if (isHome) {
      await _addTemplateDuties(txn, id);
    }
  });

  Future<void> setResult(int id, int? rkavic, int? opponent, bool done) async {
    await _db.update(
      'matches',
      {
        'rkavic_score': rkavic,
        'opponent_score': opponent,
        'done': done ? 1 : 0,
      },
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> deleteMatch(int id) => _db.transaction((txn) async {
    await txn.delete(
      'whatsapp_attendance_polls',
      where: 'match_id=?',
      whereArgs: [id],
    );
    await txn.delete('matches', where: 'id=?', whereArgs: [id]);
    await txn.delete('attendance', where: 'match_id=?', whereArgs: [id]);
    await txn.delete('duties', where: 'match_id=?', whereArgs: [id]);
  });

  Future<Map<int, int>> attendance(int matchId) async {
    final rows = await _db.query(
      'attendance',
      columns: ['player_id', 'status'],
      where: 'match_id=?',
      whereArgs: [matchId],
    );
    return {
      for (final row in rows) row['player_id'] as int: row['status'] as int,
    };
  }

  Future<AttendancePollLink?> attendancePollLink(int matchId) async {
    final rows = await _db.query(
      'whatsapp_attendance_polls',
      where: 'match_id=?',
      whereArgs: [matchId],
      limit: 1,
    );
    return rows.isEmpty ? null : AttendancePollLink.fromRow(rows.single);
  }

  Future<int?> matchLinkedToPoll(String groupId, String pollId) async {
    final rows = await _db.query(
      'whatsapp_attendance_polls',
      columns: ['match_id'],
      where: 'group_id=? AND poll_id=?',
      whereArgs: [groupId, pollId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['match_id'] as int;
  }

  Future<bool> hasLinkedAttendancePoll() async => (await _db.query(
    'whatsapp_attendance_polls',
    columns: ['match_id'],
    limit: 1,
  )).isNotEmpty;

  /// Poll links stay local so raw WhatsApp group/poll identifiers and text are
  /// not included in the shared team backup or Supabase sync payload.
  Future<void> linkAttendancePoll(AttendancePollLink link) async {
    final linkedMatch = await matchLinkedToPoll(link.groupId, link.pollId);
    if (linkedMatch != null && linkedMatch != link.matchId) {
      throw StateError('This poll is already linked to another match.');
    }
    await _db.transaction((txn) async {
      final old = await txn.query(
        'whatsapp_attendance_polls',
        where: 'match_id=?',
        whereArgs: [link.matchId],
        limit: 1,
      );
      if (old.isNotEmpty &&
          (old.single['poll_id'] != link.pollId ||
              old.single['group_id'] != link.groupId)) {
        await txn.delete(
          'whatsapp_poll_options',
          where: 'match_id=?',
          whereArgs: [link.matchId],
        );
      }
      await txn.insert('whatsapp_attendance_polls', {
        'match_id': link.matchId,
        'group_id': link.groupId,
        'poll_id': link.pollId,
        'question': link.question,
        'options_json': jsonEncode(link.options),
        'linked_at': link.linkedAt.toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> unlinkAttendancePoll(int matchId) =>
      _db.transaction((txn) async {
        await txn.delete(
          'whatsapp_attendance_polls',
          where: 'match_id=?',
          whereArgs: [matchId],
        );
        await txn.delete(
          'whatsapp_poll_options',
          where: 'match_id=?',
          whereArgs: [matchId],
        );
      });

  Future<Map<String, int>> pollOptionMappings(int matchId) async {
    final rows = await _db.query(
      'whatsapp_poll_options',
      where: 'match_id=?',
      whereArgs: [matchId],
    );
    return {
      for (final row in rows)
        row['option_name'] as String: row['status'] as int,
    };
  }

  Future<void> savePollOptionMappings(int matchId, Map<String, int> options) =>
      _db.transaction((txn) async {
        await txn.delete(
          'whatsapp_poll_options',
          where: 'match_id=?',
          whereArgs: [matchId],
        );
        for (final entry in options.entries) {
          if (entry.value < 1 || entry.value > 3)
            throw ArgumentError('Invalid attendance status');
          await txn.insert('whatsapp_poll_options', {
            'match_id': matchId,
            'option_name': entry.key,
            'status': entry.value,
          });
        }
        await txn.update(
          'whatsapp_attendance_state',
          {'vote_at': null},
          where: 'match_id=? AND manual_override=0',
          whereArgs: [matchId],
        );
      });

  Future<Map<String, Set<int>>> pollPlayerMappings(String groupId) async {
    final rows = await _db.query(
      'whatsapp_player_mappings',
      where: 'group_id=?',
      whereArgs: [groupId],
    );
    final mappings = <String, Set<int>>{};
    for (final row in rows) {
      final players = mappings.putIfAbsent(
        row['voter_id'] as String,
        () => <int>{},
      );
      final playerId = row['player_id'] as int;
      if (playerId != _ignoredVoterPlayerId) players.add(playerId);
    }
    return mappings;
  }

  Future<void> savePollPlayerMapping(
    String groupId,
    String voterId,
    Set<int> playerIds,
  ) => _db.transaction((txn) async {
    final previousMappings = await txn.query(
      'whatsapp_player_mappings',
      columns: ['player_id'],
      where: 'group_id=? AND voter_id=?',
      whereArgs: [groupId, voterId],
    );
    final previousIds = previousMappings
        .map((row) => row['player_id'] as int)
        .where((id) => id != _ignoredVoterPlayerId)
        .toSet();
    if (previousMappings.isNotEmpty &&
        previousIds.length == playerIds.length &&
        previousIds.containsAll(playerIds)) {
      return;
    }
    final oldStates = await txn.rawQuery(
      'SELECT s.match_id,s.player_id,s.last_status FROM whatsapp_attendance_state s '
      'JOIN whatsapp_attendance_polls p ON p.match_id=s.match_id '
      'WHERE p.group_id=? AND s.voter_id=? AND s.manual_override=0',
      [groupId, voterId],
    );
    for (final state in oldStates) {
      final matchId = state['match_id'] as int;
      final playerId = state['player_id'] as int;
      final current = await txn.query(
        'attendance',
        columns: ['status'],
        where: 'match_id=? AND player_id=?',
        whereArgs: [matchId, playerId],
        limit: 1,
      );
      final status = current.isEmpty ? 0 : current.single['status'] as int;
      if (status == state['last_status']) {
        await txn.delete(
          'attendance',
          where: 'match_id=? AND player_id=?',
          whereArgs: [matchId, playerId],
        );
      }
      await txn.delete(
        'whatsapp_attendance_state',
        where: 'match_id=? AND player_id=?',
        whereArgs: [matchId, playerId],
      );
    }
    await txn.delete(
      'whatsapp_player_mappings',
      where: 'group_id=? AND voter_id=?',
      whereArgs: [groupId, voterId],
    );
    for (final playerId
        in playerIds.isEmpty ? {_ignoredVoterPlayerId} : playerIds) {
      await txn.insert('whatsapp_player_mappings', {
        'group_id': groupId,
        'voter_id': voterId,
        'player_id': playerId,
      });
    }
    await txn.rawUpdate(
      'UPDATE whatsapp_attendance_state SET vote_at=NULL WHERE manual_override=0 AND voter_id=? AND match_id IN (SELECT match_id FROM whatsapp_attendance_polls WHERE group_id=?)',
      [voterId, groupId],
    );
  });

  Future<void> clearPollManualOverrides(int matchId) async {
    await _db.update(
      'whatsapp_attendance_state',
      {'manual_override': 0, 'vote_at': null},
      where: 'match_id=?',
      whereArgs: [matchId],
    );
  }

  /// Applies a linked poll using explicit mappings or unambiguous roster matches.
  Future<int> applyAttendancePoll(
    WhatsAppPollSnapshot poll,
  ) => _db.transaction((txn) async {
    final links = await txn.query(
      'whatsapp_attendance_polls',
      where: 'group_id=? AND poll_id=?',
      whereArgs: [poll.groupId, poll.id],
      limit: 1,
    );
    if (links.isEmpty || poll.allowMultipleAnswers == null) return 0;
    final matchId = links.single['match_id'] as int;
    final matches = await txn.query(
      'matches',
      columns: ['done'],
      where: 'id=?',
      whereArgs: [matchId],
      limit: 1,
    );
    if (matches.isEmpty || matches.single['done'] == 1) return 0;
    final optionRows = await txn.query(
      'whatsapp_poll_options',
      where: 'match_id=?',
      whereArgs: [matchId],
    );
    final options = {
      for (final row in optionRows)
        row['option_name'] as String: row['status'] as int,
    };
    if (poll.options.isEmpty) return 0;
    for (final option in poll.options) {
      final inferred = inferredPollStatus(option);
      if (inferred != null) options.putIfAbsent(option, () => inferred);
    }
    final mappings = await txn.query(
      'whatsapp_player_mappings',
      where: 'group_id=?',
      whereArgs: [poll.groupId],
    );
    final roster = (await txn.query('players')).map(Player.fromRow).toList();
    final mappedVoters = <String, Set<int>>{};
    for (final mapping in mappings) {
      final players = mappedVoters.putIfAbsent(
        mapping['voter_id'] as String,
        () => <int>{},
      );
      final playerId = mapping['player_id'] as int;
      if (playerId != _ignoredVoterPlayerId) players.add(playerId);
    }
    final players = <int, List<WhatsAppPollVote>>{};
    for (final vote in poll.votes) {
      if (vote.voterId.isEmpty ||
          vote.updatedAt == null ||
          vote.options.length > 1 ||
          (vote.options.isNotEmpty &&
              !options.containsKey(vote.options.single)))
        continue;
      final playerIds =
          mappedVoters[vote.voterId] ??
          inferredVoterPlayers(vote.voter, roster);
      for (final playerId in playerIds) {
        players.putIfAbsent(playerId, () => []).add(vote);
      }
    }
    var changed = 0;
    for (final entry in players.entries) {
      if (entry.value.length != 1) continue;
      final vote = entry.value.single;
      final validPlayer = await txn.query(
        'players',
        columns: ['id'],
        where: 'id=?',
        whereArgs: [entry.key],
        limit: 1,
      );
      if (validPlayer.isEmpty) continue;
      final state = await txn.query(
        'whatsapp_attendance_state',
        where: 'match_id=? AND player_id=?',
        whereArgs: [matchId, entry.key],
        limit: 1,
      );
      if (state.isNotEmpty && state.single['manual_override'] == 1) continue;
      final voteAt = vote.updatedAt!.toUtc().toIso8601String();
      final previous = state.isEmpty ? null : state.single;
      if (previous != null &&
          previous['poll_id'] == poll.id &&
          previous['voter_id'] == vote.voterId &&
          (previous['vote_at'] as String? ?? '').compareTo(voteAt) >= 0)
        continue;
      final existing = await txn.query(
        'attendance',
        columns: ['status'],
        where: 'match_id=? AND player_id=?',
        whereArgs: [matchId, entry.key],
        limit: 1,
      );
      if (state.isEmpty && existing.isNotEmpty) {
        await txn.insert('whatsapp_attendance_state', {
          'match_id': matchId,
          'player_id': entry.key,
          'manual_override': 1,
        });
        continue;
      }
      final oldStatus = existing.isEmpty ? 0 : existing.single['status'] as int;
      final newStatus = vote.options.isEmpty
          ? 0
          : options[vote.options.single]!;
      if (oldStatus != newStatus) {
        if (newStatus == 0) {
          await txn.delete(
            'attendance',
            where: 'match_id=? AND player_id=?',
            whereArgs: [matchId, entry.key],
          );
        } else {
          await txn.insert('attendance', {
            'match_id': matchId,
            'player_id': entry.key,
            'status': newStatus,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await txn.insert('whatsapp_attendance_audit', {
          'match_id': matchId,
          'player_id': entry.key,
          'poll_id': poll.id,
          'voter_id': vote.voterId,
          'old_status': oldStatus,
          'new_status': newStatus,
          'vote_at': voteAt,
        });
        changed++;
      }
      await txn.insert('whatsapp_attendance_state', {
        'match_id': matchId,
        'player_id': entry.key,
        'manual_override': 0,
        'poll_id': poll.id,
        'voter_id': vote.voterId,
        'vote_at': voteAt,
        'last_status': newStatus,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return changed;
  });

  Future<Map<int, ParticipationSummary>> participationByPlayer() async {
    final matchCountRows = await _db.rawQuery(
      'SELECT COUNT(*) AS total FROM matches',
    );
    final totalMatches = matchCountRows.first['total'] as int? ?? 0;
    final rows = await _db.rawQuery(
      'SELECT player_id, status, COUNT(*) AS total FROM attendance '
      'GROUP BY player_id, status',
    );
    final counts = <int, Map<int, int>>{};
    for (final row in rows) {
      final playerId = row['player_id'] as int;
      final status = row['status'] as int;
      final total = row['total'] as int;
      counts.putIfAbsent(playerId, () => <int, int>{})[status] = total;
    }
    final players = await this.players();
    return {
      for (final player in players)
        player.id: ParticipationSummary(
          playerId: player.id,
          present: counts[player.id]?[1] ?? 0,
          absent: counts[player.id]?[2] ?? 0,
          noResponse:
              totalMatches -
              (counts[player.id]?[1] ?? 0) -
              (counts[player.id]?[2] ?? 0),
        ),
    };
  }

  Future<void> setAttendance(int matchId, int playerId, int status) async {
    await _db.transaction((txn) async {
      await txn.insert('whatsapp_attendance_state', {
        'match_id': matchId,
        'player_id': playerId,
        'manual_override': 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (status == 0) {
        await txn.delete(
          'attendance',
          where: 'match_id=? AND player_id=?',
          whereArgs: [matchId, playerId],
        );
        return;
      }
      await txn.insert('attendance', {
        'match_id': matchId,
        'player_id': playerId,
        'status': status,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<List<Duty>> duties(int matchId) async => (await _db.query(
    'duties',
    where: 'match_id=?',
    whereArgs: [matchId],
    orderBy: 'id',
  )).map(Duty.fromRow).toList();

  Future<List<DutyTemplate>> dutyTemplates() async => (await _db.query(
    'duty_templates',
    orderBy: 'title COLLATE NOCASE, id',
  )).map(DutyTemplate.fromRow).toList();

  Future<List<ParentDutySummary>> parentDutySummaries() async {
    final players = await this.players();
    final byParent = <String, List<String>>{};
    for (final player in players) {
      final parent = player.parent.trim();
      if (parent.isEmpty) continue;
      byParent.putIfAbsent(parent, () => <String>[]).add(player.name);
    }
    final dutyRows = await _db.rawQuery(
      'SELECT parent_name, done, COUNT(*) AS total FROM duties '
      'WHERE parent_name IS NOT NULL AND parent_name != \'\' '
      'GROUP BY parent_name, done',
    );
    final counts = <String, ({int assigned, int done})>{};
    for (final row in dutyRows) {
      final parent = row['parent_name'] as String;
      final previous = counts[parent] ?? (assigned: 0, done: 0);
      final total = row['total'] as int;
      counts[parent] = (
        assigned: previous.assigned + total,
        done: previous.done + ((row['done'] as int) == 1 ? total : 0),
      );
    }
    final exemptionRows = await _db.query('parent_duty_exemptions');
    final relieved = exemptionRows
        .map((row) => row['parent_name'] as String)
        .toSet();
    final parents = {...byParent.keys, ...counts.keys, ...relieved}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [
      for (final parent in parents)
        ParentDutySummary(
          name: parent,
          children: List<String>.of(byParent[parent] ?? const [])..sort(),
          assigned: counts[parent]?.assigned ?? 0,
          done: counts[parent]?.done ?? 0,
          relieved: relieved.contains(parent),
        ),
    ];
  }

  Future<void> setParentDutyRelieved(String parentName, bool relieved) async {
    final normalized = parentName.trim();
    if (normalized.isEmpty) return;
    if (relieved) {
      await _db.insert('parent_duty_exemptions', {
        'parent_name': normalized,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return;
    }
    await _db.delete(
      'parent_duty_exemptions',
      where: 'parent_name=?',
      whereArgs: [normalized],
    );
  }

  Future<int> addDutyTemplate(String title, String description) => _db.insert(
    'duty_templates',
    {'id': _newId(), 'title': title, 'description': description},
  );

  Future<void> updateDutyTemplate(
    int id,
    String title,
    String description,
  ) async {
    await _db.update(
      'duty_templates',
      {'title': title, 'description': description},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> deleteDutyTemplate(int id) => _db.transaction((txn) async {
    await txn.delete('duty_templates', where: 'id=?', whereArgs: [id]);
    await txn.update(
      'duties',
      {'template_id': null},
      where: 'template_id=?',
      whereArgs: [id],
    );
  });

  Future<void> addTemplateDutiesForMatch(int matchId) =>
      _db.transaction((txn) => _addTemplateDuties(txn, matchId));

  Future<void> _addTemplateDuties(DatabaseExecutor txn, int matchId) async {
    final templates = await txn.query('duty_templates', orderBy: 'id');
    for (final template in templates) {
      final templateId = template['id'] as int;
      final existing = await txn.query(
        'duties',
        columns: ['id'],
        where: 'match_id=? AND template_id=?',
        whereArgs: [matchId, templateId],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      await txn.insert('duties', {
        'id': _newId(),
        'match_id': matchId,
        'template_id': templateId,
        'title': template['title'] as String,
        'description': template['description'] as String,
        'parent_name': await _nextDutyParent(txn, matchId),
        'done': 0,
      });
    }
  }

  Future<String?> _nextDutyParent(DatabaseExecutor txn, int matchId) async {
    final playerRows = await txn.query(
      'players',
      columns: ['parent'],
      where: 'parent != ?',
      whereArgs: [''],
      orderBy: 'parent COLLATE NOCASE',
    );
    final parentNames = <String>{};
    for (final row in playerRows) {
      final parent = (row['parent'] as String).trim();
      if (parent.isNotEmpty) parentNames.add(parent);
    }
    if (parentNames.isEmpty) return null;

    final exemptionRows = await txn.query('parent_duty_exemptions');
    final relieved = exemptionRows
        .map((row) => row['parent_name'] as String)
        .toSet();
    final eligible =
        parentNames.where((parent) => !relieved.contains(parent)).toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (eligible.isEmpty) return null;

    final countRows = await txn.rawQuery(
      'SELECT parent_name, COUNT(*) AS total FROM duties '
      'WHERE parent_name IS NOT NULL AND parent_name != \'\' '
      'GROUP BY parent_name',
    );
    final counts = {
      for (final row in countRows)
        row['parent_name'] as String: row['total'] as int,
    };
    final matchRows = await txn.query(
      'duties',
      columns: ['parent_name'],
      where: 'match_id=? AND parent_name IS NOT NULL AND parent_name != ?',
      whereArgs: [matchId, ''],
    );
    final alreadyAssignedThisMatch = matchRows
        .map((row) => row['parent_name'] as String)
        .toSet();
    final fresh = eligible
        .where((parent) => !alreadyAssignedThisMatch.contains(parent))
        .toList();
    final pool = fresh.isEmpty ? eligible : fresh;
    pool.sort((a, b) {
      final byCount = (counts[a] ?? 0).compareTo(counts[b] ?? 0);
      return byCount != 0
          ? byCount
          : a.toLowerCase().compareTo(b.toLowerCase());
    });
    return pool.first;
  }

  Future<int> addDuty(int matchId, String title, String description) =>
      _db.insert('duties', {
        'id': _newId(),
        'match_id': matchId,
        'title': title,
        'description': description,
        'done': 0,
      });

  Future<void> assignDuty(int id, int? playerId) async {
    String? parentName;
    if (playerId != null) {
      final playerRows = await _db.query(
        'players',
        columns: ['name', 'parent'],
        where: 'id=?',
        whereArgs: [playerId],
        limit: 1,
      );
      if (playerRows.isNotEmpty) {
        final parent = (playerRows.first['parent'] as String).trim();
        parentName = parent.isEmpty
            ? playerRows.first['name'] as String
            : parent;
      }
    }
    await _db.update(
      'duties',
      {'player_id': playerId, 'parent_name': parentName},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> assignDutyToParent(int id, String? parentName) async {
    final normalized = parentName?.trim();
    int? playerId;
    if (normalized != null && normalized.isNotEmpty) {
      final playerRows = await _db.query(
        'players',
        columns: ['id'],
        where: 'parent=?',
        whereArgs: [normalized],
        orderBy: 'name COLLATE NOCASE, id',
        limit: 1,
      );
      if (playerRows.isNotEmpty) {
        playerId = playerRows.first['id'] as int;
      }
    }
    await _db.update(
      'duties',
      {
        'player_id': playerId,
        'parent_name': normalized == null || normalized.isEmpty
            ? null
            : normalized,
      },
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> setDutyDone(int id, bool done) async {
    await _db.update(
      'duties',
      {'done': done ? 1 : 0},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> deleteDuty(int id) async {
    await _db.delete('duties', where: 'id=?', whereArgs: [id]);
  }
}
