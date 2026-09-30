import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:rkavic_manager/data/team_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('new matches store an alphanumeric field designation', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'rkavic-new-field-',
    );
    try {
      final store = await TeamStore.openAt(
        path.join(directory.path, 'team.db'),
        databaseFactoryFfi,
      );
      await store.addMatch(
        title: 'Lions',
        kickoff: '2026-10-03 10:00',
        meet: '2026-10-03 09:30',
        location: 'Home field',
        fieldNumber: '1B2',
        isHome: false,
        deadline: '2026-10-01 18:00',
      );
      expect((await store.matches()).single.venue, 'Home field • Field 1B2');
      await store.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('version 2 matches gain an empty field and keep their other data', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('rkavic-field-');
    try {
      final dbPath = path.join(directory.path, 'team.db');
      final factory = databaseFactoryFfi;
      final legacy = await factory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE matches(id INTEGER PRIMARY KEY,title TEXT NOT NULL,'
              'date TEXT NOT NULL,meet TEXT NOT NULL,location TEXT NOT NULL,'
              'deadline TEXT NOT NULL,rkavic_score INTEGER,opponent_score INTEGER,'
              'done INTEGER NOT NULL DEFAULT 0)',
            );
          },
        ),
      );
      await legacy.insert('matches', {
        'title': 'Lions',
        'date': '2026-10-03 10:00',
        'meet': '2026-10-03 09:30',
        'location': 'Home field',
        'deadline': '2026-10-01 18:00',
        'rkavic_score': 2,
        'opponent_score': 1,
        'done': 1,
      });
      await legacy.close();

      final store = await TeamStore.openAt(dbPath, factory);
      final match = (await store.matches()).single;
      expect(match.title, 'Lions');
      expect(match.fieldNumber, isEmpty);
      expect(match.rkavicScore, 2);
      expect(match.done, isTrue);

      await store.updateMatch(
        match.id,
        title: match.title,
        kickoff: match.kickoff,
        meet: match.meet,
        location: match.location,
        fieldNumber: '1B2',
        isHome: true,
        deadline: match.deadline,
      );
      await store.close();

      final reopened = await TeamStore.openAt(dbPath, factory);
      expect((await reopened.matches()).single.fieldNumber, '1B2');
      expect((await reopened.matches()).single.isHome, isTrue);
      await reopened.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'participation summaries count joined, absent, and no reply events',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'rkavic-participation-',
      );
      try {
        final store = await TeamStore.openAt(
          path.join(directory.path, 'team.db'),
          databaseFactoryFfi,
        );
        final sam = await store.addPlayer('Sam', 'Alex');
        final jo = await store.addPlayer('Jo', '');
        final first = await store.addMatch(
          title: 'Lions',
          kickoff: '2026-10-03 10:00',
          meet: '2026-10-03 09:30',
          location: 'Home field',
          fieldNumber: '1B2',
          isHome: false,
          deadline: '2026-10-01 18:00',
        );
        await store.addMatch(
          title: 'Tigers',
          kickoff: '2026-10-10 10:00',
          meet: '2026-10-10 09:30',
          location: 'Away field',
          fieldNumber: '2',
          isHome: false,
          deadline: '2026-10-08 18:00',
        );
        await store.setAttendance(first, sam, 1);
        await store.setAttendance(first, jo, 2);

        final summaries = await store.participationByPlayer();
        expect(summaries[sam]!.present, 1);
        expect(summaries[sam]!.absent, 0);
        expect(summaries[sam]!.noResponse, 1);
        expect(summaries[jo]!.present, 0);
        expect(summaries[jo]!.absent, 1);
        expect(summaries[jo]!.noResponse, 1);
        await store.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('attendance can be acknowledged, cancelled, and cleared', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'rkavic-attendance-',
    );
    try {
      final store = await TeamStore.openAt(
        path.join(directory.path, 'team.db'),
        databaseFactoryFfi,
      );
      final playerId = await store.addPlayer('Sam', 'Alex');
      final matchId = await store.addMatch(
        title: 'Lions',
        kickoff: '2026-10-03 10:00',
        meet: '2026-10-03 09:30',
        location: 'Home field',
        fieldNumber: '1B2',
        isHome: false,
        deadline: '2026-10-01 18:00',
      );

      await store.setAttendance(matchId, playerId, 1);
      expect(await store.attendance(matchId), {playerId: 1});

      await store.setAttendance(matchId, playerId, 2);
      expect(await store.attendance(matchId), {playerId: 2});

      await store.setAttendance(matchId, playerId, 0);
      expect(await store.attendance(matchId), isEmpty);

      await store.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('home matches receive reusable duty shifts with descriptions', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'rkavic-home-duties-',
    );
    try {
      final store = await TeamStore.openAt(
        path.join(directory.path, 'team.db'),
        databaseFactoryFfi,
      );
      await store.addPlayer('Sam', 'Alex');
      await store.addPlayer('Jo', 'Britt');
      final templateId = await store.addDutyTemplate(
        'Field setup',
        'Place goals, flags, and cones before kickoff.',
      );
      final homeMatch = await store.addMatch(
        title: 'Lions',
        kickoff: '2026-10-03 10:00',
        meet: '2026-10-03 09:30',
        location: 'Home field',
        fieldNumber: '1B2',
        isHome: true,
        deadline: '2026-10-01 18:00',
      );
      await store.addMatch(
        title: 'Tigers',
        kickoff: '2026-10-10 10:00',
        meet: '2026-10-10 09:30',
        location: 'Away field',
        fieldNumber: '2',
        isHome: false,
        deadline: '2026-10-08 18:00',
      );

      final homeDuties = await store.duties(homeMatch);
      expect(homeDuties.single.templateId, templateId);
      expect(homeDuties.single.title, 'Field setup');
      expect(homeDuties.single.parentName, 'Alex');
      expect(
        homeDuties.single.description,
        'Place goals, flags, and cones before kickoff.',
      );

      await store.addTemplateDutiesForMatch(homeMatch);
      expect(await store.duties(homeMatch), hasLength(1));
      await store.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('automatic duty assignment skips relieved parents', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'rkavic-relieved-duties-',
    );
    try {
      final store = await TeamStore.openAt(
        path.join(directory.path, 'team.db'),
        databaseFactoryFfi,
      );
      await store.addPlayer('Sam', 'Alex');
      await store.addPlayer('Jo', 'Britt');
      await store.setParentDutyRelieved('Alex', true);
      await store.addDutyTemplate('Field setup', '');
      await store.addDutyTemplate('Canteen shift', '');
      final match = await store.addMatch(
        title: 'Lions',
        kickoff: '2026-10-03 10:00',
        meet: '2026-10-03 09:30',
        location: 'Home field',
        fieldNumber: '1B2',
        isHome: true,
        deadline: '2026-10-01 18:00',
      );

      final duties = await store.duties(match);
      expect(duties.map((duty) => duty.parentName), everyElement('Britt'));
      final summaries = await store.parentDutySummaries();
      expect(
        summaries.singleWhere((parent) => parent.name == 'Alex').relieved,
        isTrue,
      );
      expect(
        summaries.singleWhere((parent) => parent.name == 'Britt').assigned,
        2,
      );
      await store.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
