import 'team_store.dart';

String _fieldLine(TeamMatch match) =>
    match.fieldNumber.isEmpty ? '' : 'Field: ${match.fieldNumber}\n';

String invitationDraft(TeamMatch match) {
  final field = _fieldLine(match);
  return '⚽ ${match.title}\n'
      '📅 ${match.kickoff}\n'
      '⏰ Meet: ${match.meet}\n'
      '📍 ${match.location}\n'
      '$field'
      'Please confirm attendance by ${match.deadline}. 🙏';
}

String reminderDraft(
  TeamMatch match,
  List<Player> players,
  Map<int, int> attendance,
) {
  final missing = players
      .where((player) => (attendance[player.id] ?? 0) == 0)
      .map((player) => player.name)
      .join(', ');
  return '⏰ Attendance reminder for ${match.title} (${match.kickoff})\n'
      'Still waiting for: ${missing.isEmpty ? 'everyone has replied ✅' : missing}\n'
      'Please reply by ${match.deadline}. 🙏';
}

String dutiesDraft(TeamMatch match, List<Player> players, List<Duty> duties) {
  final lines = duties
      .map((duty) {
        Player? player;
        for (final candidate in players) {
          if (candidate.id == duty.playerId) player = candidate;
        }
        final who = player == null
            ? 'volunteer needed'
            : player.parent.isEmpty
            ? player.name
            : player.parent;
        return '• ${duty.title}: $who';
      })
      .join('\n');
  return '🟠 Match duties · ${match.title} (${match.kickoff})\n'
      '${lines.isEmpty ? 'No duties assigned yet.' : lines}\n'
      'If unavailable, please arrange a replacement and inform me.';
}

String substitutesDraft(TeamMatch match) {
  final field = _fieldLine(match);
  return '🚨 Substitute players needed for ${match.title}\n'
      '📅 ${match.kickoff}\n'
      '⏰ Meet: ${match.meet}\n'
      '📍 ${match.location}\n'
      '$field'
      'Who can help? 🙏⚽';
}
