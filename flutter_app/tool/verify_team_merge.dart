import 'dart:convert';

import 'package:rkavic_manager/data/team_backup.dart';
import 'package:rkavic_manager/data/team_merge.dart';

TeamBackup backup({
  List<Map<String, Object?>> players = const [],
  List<Map<String, Object?>> matches = const [],
}) => TeamBackup.fromJsonString(
  jsonEncode({
    'format': TeamBackup.format,
    'version': TeamBackup.version,
    'exportedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
    'players': players,
    'matches': matches,
    'attendance': [],
    'duties': [],
    'dutyTemplates': [],
    'parentDutyExemptions': [],
  }),
);

void main() {
  final original = backup(
    players: [
      {'id': 1, 'name': 'A', 'parent': 'P'},
    ],
  );
  final local = backup(
    players: [
      {'id': 1, 'name': 'A local', 'parent': 'P'},
    ],
  );
  final separate = backup(
    players: [
      {'id': 1, 'name': 'A', 'parent': 'P'},
      {'id': 2, 'name': 'B', 'parent': 'Q'},
    ],
  );
  final independent = TeamMerge.compare(original, local, separate);
  assert(independent.conflicts.isEmpty);
  assert(independent.resolve({}).players.length == 2);
  assert(independent.resolve({}).players.first['name'] == 'A local');

  final overlapping = TeamMerge.compare(
    original,
    local,
    backup(
      players: [
        {'id': 1, 'name': 'A cloud', 'parent': 'P'},
      ],
    ),
  );
  assert(overlapping.conflicts.length == 1);
  assert(overlapping.resolve({}).players.single['name'] == 'A local');
  assert(
    overlapping.resolve({'players:1'}).players.single['name'] == 'A cloud',
  );
  assert(overlapping.resolve({}).players.single['name'] == 'A local');

  final deletion = TeamMerge.compare(
    original,
    backup(),
    backup(
      players: [
        {'id': 1, 'name': 'A cloud', 'parent': 'P'},
      ],
    ),
  );
  assert(deletion.conflicts.length == 1);
  assert(deletion.resolve({}).players.isEmpty);
  assert(deletion.resolve({'players:1'}).players.single['name'] == 'A cloud');
}
