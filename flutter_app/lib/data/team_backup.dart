import 'dart:convert';

/// A portable snapshot of the four tables that make up one local team.
class TeamBackup {
  const TeamBackup._({
    required this.exportedAt,
    required this.players,
    required this.matches,
    required this.attendance,
    required this.duties,
  });

  static const format = 'rkavic-team-manager';
  static const version = 1;

  final DateTime exportedAt;
  final List<Map<String, Object?>> players;
  final List<Map<String, Object?>> matches;
  final List<Map<String, Object?>> attendance;
  final List<Map<String, Object?>> duties;

  factory TeamBackup.capture({
    required List<Map<String, Object?>> players,
    required List<Map<String, Object?>> matches,
    required List<Map<String, Object?>> attendance,
    required List<Map<String, Object?>> duties,
  }) => TeamBackup._(
    exportedAt: DateTime.now().toUtc(),
    players: players,
    matches: matches,
    attendance: attendance,
    duties: duties,
  );

  String toJsonString() => const JsonEncoder.withIndent('  ').convert({
    'format': format,
    'version': version,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'players': players,
    'matches': matches,
    'attendance': attendance,
    'duties': duties,
  });

  factory TeamBackup.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != format ||
        decoded['version'] != version) {
      throw const FormatException('This is not a supported RKAVIC backup.');
    }
    final exportedAt = DateTime.tryParse(
      decoded['exportedAt'] is String ? decoded['exportedAt'] as String : '',
    );
    if (exportedAt == null) {
      throw const FormatException('The backup date is invalid.');
    }

    final backup = TeamBackup._(
      exportedAt: exportedAt,
      players: _rows(decoded['players'], 'players', {'id', 'name', 'parent'}),
      matches: _rows(decoded['matches'], 'matches', {
        'id',
        'title',
        'date',
        'meet',
        'location',
        'field_number',
        'deadline',
        'rkavic_score',
        'opponent_score',
        'done',
      }),
      attendance: _rows(decoded['attendance'], 'attendance', {
        'match_id',
        'player_id',
        'status',
      }),
      duties: _rows(decoded['duties'], 'duties', {
        'id',
        'match_id',
        'title',
        'player_id',
        'done',
      }),
    );
    backup._validate();
    return backup;
  }

  static List<Map<String, Object?>> _rows(
    Object? value,
    String table,
    Set<String> columns,
  ) {
    if (value is! List) throw FormatException('Missing $table data.');
    return value.map((item) {
      if (item is! Map<String, dynamic> ||
          item.keys.toSet().difference(columns).isNotEmpty ||
          columns.difference(item.keys.toSet()).isNotEmpty) {
        throw FormatException('Invalid $table data.');
      }
      return Map<String, Object?>.from(item);
    }).toList();
  }

  static int _id(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is! int || value <= 0) {
      throw FormatException('Invalid $key in backup.');
    }
    return value;
  }

  static int? _optionalId(Map<String, Object?> row, String key) {
    final value = row[key];
    return value == null ? null : _id(row, key);
  }

  static void _string(Map<String, Object?> row, String key) {
    if (row[key] is! String) {
      throw FormatException('Invalid $key in backup.');
    }
  }

  static void _flag(Map<String, Object?> row, String key) {
    if (row[key] != 0 && row[key] != 1) {
      throw FormatException('Invalid $key in backup.');
    }
  }

  void _validate() {
    final playerIds = <int>{};
    for (final row in players) {
      if (!playerIds.add(_id(row, 'id'))) {
        throw const FormatException('Duplicate player in backup.');
      }
      _string(row, 'name');
      _string(row, 'parent');
    }

    final matchIds = <int>{};
    for (final row in matches) {
      if (!matchIds.add(_id(row, 'id'))) {
        throw const FormatException('Duplicate match in backup.');
      }
      for (final key in [
        'title',
        'date',
        'meet',
        'location',
        'field_number',
        'deadline',
      ]) {
        _string(row, key);
      }
      _flag(row, 'done');
      final ours = row['rkavic_score'];
      final theirs = row['opponent_score'];
      if ((ours == null) != (theirs == null) ||
          (ours != null && (ours is! int || ours < 0)) ||
          (theirs != null && (theirs is! int || theirs < 0))) {
        throw const FormatException('Invalid match result in backup.');
      }
    }

    final attendanceKeys = <String>{};
    for (final row in attendance) {
      final matchId = _id(row, 'match_id');
      final playerId = _id(row, 'player_id');
      if (!matchIds.contains(matchId) ||
          !playerIds.contains(playerId) ||
          !attendanceKeys.add('$matchId:$playerId')) {
        throw const FormatException('Invalid attendance in backup.');
      }
      if (row['status'] is! int ||
          (row['status'] as int) < 0 ||
          (row['status'] as int) > 2) {
        throw const FormatException('Invalid attendance status in backup.');
      }
    }

    final dutyIds = <int>{};
    for (final row in duties) {
      if (!dutyIds.add(_id(row, 'id')) ||
          !matchIds.contains(_id(row, 'match_id'))) {
        throw const FormatException('Invalid duty in backup.');
      }
      final playerId = _optionalId(row, 'player_id');
      if (playerId != null && !playerIds.contains(playerId)) {
        throw const FormatException('Invalid duty player in backup.');
      }
      _string(row, 'title');
      _flag(row, 'done');
    }
  }
}
