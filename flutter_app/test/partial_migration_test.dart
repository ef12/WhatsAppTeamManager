import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:rkavic_manager/data/team_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('upgrades a version 3 database with later columns already present', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('rkavic-partial-');
    try {
      final dbPath = path.join(directory.path, 'team.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE players(id INTEGER PRIMARY KEY,name TEXT NOT NULL,'
              'parent TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE matches(id INTEGER PRIMARY KEY,title TEXT NOT NULL,'
              'date TEXT NOT NULL,meet TEXT NOT NULL,location TEXT NOT NULL,'
              "field_number TEXT NOT NULL DEFAULT '',"
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
              'template_id INTEGER,title TEXT NOT NULL,'
              "description TEXT NOT NULL DEFAULT '',"
              'player_id INTEGER,parent_name TEXT,done INTEGER NOT NULL DEFAULT 0)',
            );
            await db.execute(
              'CREATE TABLE duty_templates(id INTEGER PRIMARY KEY,'
              "title TEXT NOT NULL,description TEXT NOT NULL DEFAULT '')",
            );
            await db.execute(
              'CREATE TABLE parent_duty_exemptions(parent_name TEXT PRIMARY KEY)',
            );
          },
        ),
      );
      await legacy.insert('players', {'name': 'Sam', 'parent': 'Alex'});
      await legacy.insert('matches', {
        'title': 'Lions',
        'date': '2026-10-03 10:00',
        'meet': '2026-10-03 09:30',
        'location': 'Home field',
        'field_number': '1B2',
        'is_home': 1,
        'deadline': '2026-10-01 18:00',
      });
      await legacy.insert('duties', {
        'match_id': 1,
        'title': 'Field setup',
        'parent_name': 'Alex',
      });
      await legacy.close();

      final store = await TeamStore.openAt(dbPath, databaseFactoryFfi);
      expect((await store.players()).single.name, 'Sam');
      expect((await store.matches()).single.isHome, isTrue);
      expect((await store.matches()).single.fieldNumber, '1B2');
      expect((await store.duties(1)).single.parentName, 'Alex');
      expect((await store.localSyncState()).localRevision, 0);
      await store.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
