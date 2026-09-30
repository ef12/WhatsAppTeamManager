import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as desktop;

import 'team_backup.dart';

class Player {
  const Player(this.id, this.name, this.parent);

  final int id;
  final String name;
  final String parent;

  factory Player.fromRow(Map<String, Object?> row) =>
      Player(row['id'] as int, row['name'] as String, row['parent'] as String);
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

class Duty {
  const Duty(
    this.id,
    this.matchId,
    this.templateId,
    this.title,
    this.description,
    this.playerId,
    this.done,
  );

  final int id;
  final int matchId;
  final int? templateId;
  final String title;
  final String description;
  final int? playerId;
  final bool done;

  factory Duty.fromRow(Map<String, Object?> row) => Duty(
    row['id'] as int,
    row['match_id'] as int,
    row['template_id'] as int?,
    row['title'] as String,
    row['description'] as String,
    row['player_id'] as int?,
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

class TeamStore {
  TeamStore._(this._db);

  final Database _db;

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
        version: 4,
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
            'player_id INTEGER,done INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE duty_templates(id INTEGER PRIMARY KEY,'
            'title TEXT NOT NULL,description TEXT NOT NULL DEFAULT \'\')',
          );
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
            await db.execute(
              'ALTER TABLE matches ADD COLUMN is_home INTEGER NOT NULL DEFAULT 0',
            );
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
              await db.execute(
                'ALTER TABLE duties ADD COLUMN template_id INTEGER',
              );
              await db.execute(
                "ALTER TABLE duties ADD COLUMN description TEXT NOT NULL DEFAULT ''",
              );
            }
            await db.execute(
              'CREATE TABLE IF NOT EXISTS duty_templates(id INTEGER PRIMARY KEY,'
              'title TEXT NOT NULL,description TEXT NOT NULL DEFAULT \'\')',
            );
          }
        },
      ),
    );
    return TeamStore._(db);
  }

  Future<void> close() => _db.close();

  Future<TeamBackup> exportBackup() => _db.transaction(
    (txn) async => TeamBackup.capture(
      players: await txn.query('players', orderBy: 'id'),
      matches: await txn.query('matches', orderBy: 'id'),
      attendance: await txn.query('attendance', orderBy: 'match_id, player_id'),
      duties: await txn.query('duties', orderBy: 'id'),
      dutyTemplates: await txn.query('duty_templates', orderBy: 'id'),
    ),
  );

  Future<void> replaceWithBackup(TeamBackup backup) =>
      _db.transaction((txn) async {
        for (final table in [
          'attendance',
          'duties',
          'duty_templates',
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
      });

  Future<List<Player>> players() async => (await _db.query(
    'players',
    orderBy: 'name COLLATE NOCASE, id',
  )).map(Player.fromRow).toList();

  Future<int> addPlayer(String name, String parent) =>
      _db.insert('players', {'name': name, 'parent': parent});

  Future<void> updatePlayer(int id, String name, String parent) async {
    await _db.update(
      'players',
      {'name': name, 'parent': parent},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlayer(int id) => _db.transaction((txn) async {
    await txn.delete('players', where: 'id=?', whereArgs: [id]);
    await txn.delete('attendance', where: 'player_id=?', whereArgs: [id]);
    await txn.rawUpdate('UPDATE duties SET player_id=NULL WHERE player_id=?', [
      id,
    ]);
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
    if (status == 0) {
      await _db.delete(
        'attendance',
        where: 'match_id=? AND player_id=?',
        whereArgs: [matchId, playerId],
      );
      return;
    }
    await _db.insert('attendance', {
      'match_id': matchId,
      'player_id': playerId,
      'status': status,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  Future<int> addDutyTemplate(String title, String description) => _db.insert(
    'duty_templates',
    {'title': title, 'description': description},
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
        'match_id': matchId,
        'template_id': templateId,
        'title': template['title'] as String,
        'description': template['description'] as String,
        'done': 0,
      });
    }
  }

  Future<int> addDuty(int matchId, String title, String description) =>
      _db.insert('duties', {
        'match_id': matchId,
        'title': title,
        'description': description,
        'done': 0,
      });

  Future<void> assignDuty(int id, int? playerId) async {
    await _db.update(
      'duties',
      {'player_id': playerId},
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
