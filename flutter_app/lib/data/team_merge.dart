import 'dart:convert';

import 'team_backup.dart';

class RowConflict {
  const RowConflict(this.table, this.key, this.local, this.remote);
  final String table;
  final String key;
  final Map<String, Object?>? local;
  final Map<String, Object?>? remote;

  String get label => '$table: $key';
}

class TeamMerge {
  TeamMerge._(this._document, this.conflicts);
  final Map<String, dynamic> _document;
  final List<RowConflict> conflicts;

  static const _keys = <String, List<String>>{
    'players': ['id'],
    'matches': ['id'],
    'attendance': ['match_id', 'player_id'],
    'duties': ['id'],
    'dutyTemplates': ['id'],
    'parentDutyExemptions': ['parent_name'],
  };

  static TeamMerge compare(
    TeamBackup baseline,
    TeamBackup local,
    TeamBackup remote,
  ) {
    final base = jsonDecode(baseline.toJsonString()) as Map<String, dynamic>;
    final mine = jsonDecode(local.toJsonString()) as Map<String, dynamic>;
    final theirs = jsonDecode(remote.toJsonString()) as Map<String, dynamic>;
    final conflicts = <RowConflict>[];
    for (final entry in _keys.entries) {
      final table = entry.key;
      String key(Map<String, dynamic> row) =>
          entry.value.map((column) => row[column].toString()).join(':');
      Map<String, Map<String, dynamic>> index(Map<String, dynamic> source) => {
        for (final item in source[table] as List)
          key(item as Map<String, dynamic>): item,
      };
      final before = index(base);
      final current = index(mine);
      final incoming = index(theirs);
      final merged = <Map<String, dynamic>>[];
      for (final id in {...before.keys, ...current.keys, ...incoming.keys}) {
        final original = before[id];
        final localRow = current[id];
        final remoteRow = incoming[id];
        final localChanged = !_same(localRow, original);
        final remoteChanged = !_same(remoteRow, original);
        Map<String, dynamic>? chosen;
        if (!localChanged) {
          chosen = remoteRow;
        } else if (!remoteChanged || _same(localRow, remoteRow)) {
          chosen = localRow;
        } else {
          conflicts.add(
            RowConflict(
              table,
              id,
              localRow == null ? null : Map<String, Object?>.from(localRow),
              remoteRow == null ? null : Map<String, Object?>.from(remoteRow),
            ),
          );
          chosen = localRow;
        }
        if (chosen != null) merged.add(chosen);
      }
      theirs[table] = merged;
    }
    theirs['exportedAt'] = DateTime.now().toUtc().toIso8601String();
    return TeamMerge._(theirs, conflicts);
  }

  static bool _same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => i).every((i) => _same(a[i], b[i]));
    }
    return a == b;
  }

  TeamBackup resolve(Set<String> useCloud) {
    final document = jsonDecode(jsonEncode(_document)) as Map<String, dynamic>;
    for (final conflict in conflicts) {
      if (!useCloud.contains('${conflict.table}:${conflict.key}')) continue;
      final rows = document[conflict.table] as List;
      final keyColumns = _keys[conflict.table]!;
      String key(Map row) => keyColumns.map((column) => row[column]).join(':');
      rows.removeWhere((row) => key(row as Map) == conflict.key);
      if (conflict.remote != null) rows.add(conflict.remote);
    }
    return TeamBackup.fromJsonString(jsonEncode(document));
  }
}
