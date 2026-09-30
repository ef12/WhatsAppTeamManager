import 'team_store.dart';

String _fieldLine(TeamMatch match) =>
    match.fieldNumber.isEmpty ? '' : 'Field: ${match.fieldNumber}\n';

String _mapsLine(TeamMatch match) =>
    match.mapsUri == null ? '' : 'Map: ${match.mapsUri}\n';

String invitationDraft(TeamMatch match) {
  final field = _fieldLine(match);
  return '⚽ ${match.title}\n'
      '📅 ${match.kickoff}\n'
      '⏰ Meet: ${match.meet}\n'
      '📍 ${match.location}\n'
      '$field'
      '${_mapsLine(match)}'
      'Please confirm attendance by ${match.deadline}. 🙏';
}

String attendancePollDraft(TeamMatch match) =>
    'Poll for ${match.title}\n'
    'Question: Can you join this match?\n'
    'Options:\n'
    '1. Yes\n'
    '2. No\n'
    '3. Maybe\n\n'
    'Match: ${match.kickoff}\n'
    'Meet: ${match.meet}\n'
    'Reply deadline: ${match.deadline}';

String resultDraft(TeamMatch match, Map<int, int> attendance) {
  final ours = match.rkavicScore;
  final theirs = match.opponentScore;
  final score = ours == null || theirs == null
      ? 'Result not entered yet'
      : 'RKAVIC $ours - $theirs Opponent';
  final outcome = ours == null || theirs == null
      ? 'Thank you for a good match.'
      : ours > theirs
      ? 'A strong win for the team.'
      : ours == theirs
      ? 'A hard-earned draw.'
      : 'Heads up, we go again next time.';
  final present = attendance.values.where((status) => status == 1).length;
  return 'Final result - ${match.title}\n'
      '$score\n\n'
      '$outcome\n'
      'Players marked present: $present\n'
      'Thanks everyone for the effort and support.';
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
      '${_mapsLine(match)}'
      'Who can help? 🙏⚽';
}
