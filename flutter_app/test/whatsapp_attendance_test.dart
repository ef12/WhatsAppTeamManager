import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:rkavic_manager/data/team_store.dart';
import 'package:rkavic_manager/data/whatsapp_message_reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'configured poll updates mapped players once and respects manual overrides',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'attendance-poll-',
      );
      final store = await TeamStore.openAt(
        path.join(directory.path, 'team.db'),
        databaseFactoryFfi,
      );
      try {
        final player = await store.addPlayer('Sam', 'Alex');
        final sibling = await store.addPlayer('Jo', 'Alex');
        final match = await store.addMatch(
          title: 'Match',
          kickoff: '2026-11-20',
          meet: '',
          location: '',
          fieldNumber: '',
          isHome: false,
          deadline: '',
        );
        await store.linkAttendancePoll(
          AttendancePollLink(
            matchId: match,
            groupId: 'group',
            pollId: 'poll',
            question: 'Coming?',
            options: const ['Yes', 'No'],
            linkedAt: DateTime.utc(2026),
          ),
        );
        WhatsAppPollSnapshot snapshot(
          String selected,
          int minute, {
          String group = 'group',
          bool? multi = false,
          List<String>? choices,
        }) => WhatsAppPollSnapshot(
          id: 'poll',
          groupId: group,
          question: 'Coming?',
          createdAt: DateTime.utc(2026),
          options: const ['Yes', 'No'],
          allowMultipleAnswers: multi,
          votes: [
            WhatsAppPollVote(
              voterId: 'parent',
              voter: 'Alex',
              options: choices ?? (selected.isEmpty ? [] : [selected]),
              updatedAt: DateTime.utc(2026, 1, 1, 0, minute),
            ),
          ],
        );
        expect(await store.applyAttendancePoll(snapshot('Yes', 1)), 0);
        await store.savePollOptionMappings(match, {'Yes': 1, 'No': 2});
        await store.savePollPlayerMapping('group', 'parent', {player, sibling});
        expect(
          await store.applyAttendancePoll(snapshot('Yes', 1, group: 'other')),
          0,
        );
        expect(await store.applyAttendancePoll(snapshot('Yes', 1, multi: true)), 2);
        expect(await store.attendance(match), {player: 1, sibling: 1});
        expect(
          await store.applyAttendancePoll(
            snapshot('Yes', 2, multi: true, choices: ['Yes', 'No']),
          ),
          0,
        );
        expect(await store.attendance(match), {player: 1, sibling: 1});
        expect(await store.applyAttendancePoll(snapshot('Yes', 1)), 0);
        await store.savePollOptionMappings(match, {'Yes': 2, 'No': 1});
        expect(await store.applyAttendancePoll(snapshot('Yes', 1)), 2);
        expect(await store.attendance(match), {player: 2, sibling: 2});
        await store.savePollOptionMappings(match, {'Yes': 1, 'No': 2});
        expect(await store.applyAttendancePoll(snapshot('Yes', 1)), 2);
        expect(await store.applyAttendancePoll(snapshot('No', 2)), 2);
        await store.setAttendance(match, player, 3);
        expect(await store.applyAttendancePoll(snapshot('', 3)), 1);
        expect(await store.attendance(match), {player: 3});
        await store.clearPollManualOverrides(match);
        expect(await store.applyAttendancePoll(snapshot('Yes', 4)), 2);
        expect(await store.attendance(match), {player: 1, sibling: 1});
        await store.setResult(match, null, null, true);
        expect(await store.applyAttendancePoll(snapshot('No', 5)), 0);
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
