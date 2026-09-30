import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:rkavic_manager/data/team_backup.dart';
import 'package:rkavic_manager/data/team_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'a JSON backup restores every team table and replaces old data',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp('rkavic-backup-');
      try {
        final source = await TeamStore.openAt(
          path.join(directory.path, 'source.db'),
          databaseFactoryFfi,
        );
        final playerId = await source.addPlayer('Sam', 'Alex');
        final matchId = await source.addMatch(
          title: 'Lions',
          kickoff: '2026-10-03 10:00',
          meet: '2026-10-03 09:30',
          location: 'Sportpark De Meern',
          fieldNumber: '1B2',
          isHome: true,
          deadline: '2026-10-01 18:00',
        );
        await source.setAttendance(matchId, playerId, 1);
        await source.addDutyTemplate(
          'Canteen shift',
          'Help with drinks after the match.',
        );
        await source.setParentDutyRelieved('Trainer', true);
        await source.addTemplateDutiesForMatch(matchId);
        final dutyId = await source.addDuty(
          matchId,
          'Field setup',
          'Place goals, flags, and cones before kickoff.',
        );
        await source.assignDuty(dutyId, playerId);
        await source.setDutyDone(dutyId, true);
        await source.setResult(matchId, 2, 1, true);
        final json = (await source.exportBackup()).toJsonString();
        await source.close();

        final target = await TeamStore.openAt(
          path.join(directory.path, 'target.db'),
          databaseFactoryFfi,
        );
        await target.addPlayer('Old player', '');
        await target.replaceWithBackup(TeamBackup.fromJsonString(json));
        expect((await target.players()).single.name, 'Sam');
        expect((await target.players()).single.parent, 'Alex');
        final restored = (await target.matches()).single;
        expect(restored.location, 'Sportpark De Meern');
        expect(restored.fieldNumber, '1B2');
        expect(restored.isHome, isTrue);
        expect(restored.rkavicScore, 2);
        expect(restored.opponentScore, 1);
        expect(restored.done, isTrue);
        expect(await target.attendance(matchId), {playerId: 1});
        final templates = await target.dutyTemplates();
        expect(templates.single.title, 'Canteen shift');
        expect(
          templates.single.description,
          'Help with drinks after the match.',
        );
        final duties = await target.duties(matchId);
        final duty = duties.singleWhere((duty) => duty.title == 'Field setup');
        expect(duty.title, 'Field setup');
        expect(
          duty.description,
          'Place goals, flags, and cones before kickoff.',
        );
        expect(duty.playerId, playerId);
        expect(duty.parentName, 'Alex');
        expect(duty.done, isTrue);
        final summaries = await target.parentDutySummaries();
        expect(
          summaries
              .singleWhere((summary) => summary.name == 'Trainer')
              .relieved,
          isTrue,
        );
        await target.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('invalid references and unsupported versions are rejected', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('rkavic-invalid-');
    try {
      final store = await TeamStore.openAt(
        path.join(directory.path, 'team.db'),
        databaseFactoryFfi,
      );
      await store.addPlayer('Keep me', '');
      final backup = await store.exportBackup();
      final data = jsonDecode(backup.toJsonString()) as Map<String, dynamic>;
      data['version'] = 999;
      expect(
        () => TeamBackup.fromJsonString(jsonEncode(data)),
        throwsFormatException,
      );

      data['version'] = TeamBackup.version;
      data['attendance'] = [
        {'match_id': 5, 'player_id': 1, 'status': 1},
      ];
      expect(
        () => TeamBackup.fromJsonString(jsonEncode(data)),
        throwsFormatException,
      );
      expect((await store.players()).single.name, 'Keep me');
      await store.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
