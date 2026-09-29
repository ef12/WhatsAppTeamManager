import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/message_drafts.dart';
import 'data/team_store.dart';

const forest = Color(0xFF163E35);
const lime = Color(0xFFD8F27A);
const canvas = Color(0xFFF5F7F3);
final dateFormat = DateFormat('yyyy-MM-dd HH:mm');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await TeamStore.open();
  runApp(TeamManagerApp(store: store));
}

class TeamManagerApp extends StatelessWidget {
  const TeamManagerApp({super.key, required this.store});
  final TeamStore store;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'RKAVIC Team Manager',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: forest, surface: canvas),
      scaffoldBackgroundColor: canvas,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    home: TeamHome(store: store),
  );
}

class TeamHome extends StatefulWidget {
  const TeamHome({super.key, required this.store});
  final TeamStore store;

  @override
  State<TeamHome> createState() => _TeamHomeState();
}

class _TeamHomeState extends State<TeamHome> {
  int page = 0;
  int? selectedMatchId;
  List<Player> players = [];
  List<TeamMatch> matches = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final values = await Future.wait([
      widget.store.players(),
      widget.store.matches(),
    ]);
    if (!mounted) return;
    setState(() {
      players = values[0] as List<Player>;
      matches = values[1] as List<TeamMatch>;
      loading = false;
    });
  }

  void showMatch(int id) => setState(() {
    selectedMatchId = id;
    page = 1;
  });

  void navigate(int index) => setState(() {
    page = index;
    selectedMatchId = null;
  });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 850;
    final selected = matches.where((m) => m.id == selectedMatchId).firstOrNull;
    final content = loading
        ? const Center(child: CircularProgressIndicator())
        : selected != null
        ? _matchDetail(selected)
        : page == 0
        ? _dashboard()
        : page == 1
        ? _matches()
        : _players();
    return Scaffold(
      body: Row(
        children: [
          if (wide) _sidebar(),
          Expanded(
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1140),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(wide ? 36 : 20),
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: navigate,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.space_dashboard_outlined),
                  selectedIcon: Icon(Icons.space_dashboard),
                  label: 'Overview',
                ),
                NavigationDestination(
                  icon: Icon(Icons.sports_soccer_outlined),
                  selectedIcon: Icon(Icons.sports_soccer),
                  label: 'Matches',
                ),
                NavigationDestination(
                  icon: Icon(Icons.groups_outlined),
                  selectedIcon: Icon(Icons.groups),
                  label: 'Players',
                ),
              ],
            ),
    );
  }

  Widget _sidebar() => Container(
    width: 244,
    color: forest,
    padding: const EdgeInsets.fromLTRB(18, 28, 18, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: lime,
                child: Icon(Icons.sports_soccer, color: forest),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'RKAVIC\nTEAM MANAGER',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 42),
        _navItem(0, Icons.space_dashboard_outlined, 'Overview'),
        _navItem(1, Icons.sports_soccer_outlined, 'Matches'),
        _navItem(2, Icons.groups_outlined, 'Players'),
        const Spacer(),
        const Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'LOCAL & PRIVATE\nMessages are shared by you.',
            style: TextStyle(
              color: Color(0xFFB7C8BE),
              fontSize: 11,
              height: 1.6,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _navItem(int index, IconData icon, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      tileColor: page == index ? const Color(0xFF315A49) : null,
      leading: Icon(icon, color: page == index ? lime : Colors.white70),
      title: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: page == index ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      onTap: () => navigate(index),
    ),
  );

  Widget _heading(
    String eyebrow,
    String title,
    String subtitle, {
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 26),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 18,
      runSpacing: 14,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFF60806C),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              title,
              style: const TextStyle(
                color: forest,
                fontSize: 34,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            Text(subtitle, style: const TextStyle(color: Color(0xFF687970))),
          ],
        ),
        ?action,
      ],
    ),
  );

  Widget _dashboard() {
    final upcoming = matches.where((m) => !m.done).toList();
    final completed = matches.length - upcoming.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'Your team at a glance',
          'Good to see you.',
          'Everything for match day, in one place.',
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: forest,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 22,
            runSpacing: 18,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'NEXT UP',
                    style: TextStyle(
                      color: lime,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    upcoming.isEmpty
                        ? 'Ready for the next match?'
                        : upcoming.first.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    upcoming.isEmpty
                        ? 'Create a match to get started.'
                        : '${upcoming.first.kickoff}  •  ${upcoming.first.location}',
                    style: const TextStyle(color: Color(0xFFD1E0D5)),
                  ),
                ],
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: lime,
                  foregroundColor: forest,
                ),
                onPressed: upcoming.isEmpty
                    ? () => _editMatch()
                    : () => showMatch(upcoming.first.id),
                icon: Icon(upcoming.isEmpty ? Icons.add : Icons.arrow_forward),
                label: Text(upcoming.isEmpty ? 'Add match' : 'View match'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _stat('Upcoming matches', upcoming.length, Icons.event_outlined),
            _stat('Players', players.length, Icons.groups_outlined),
            _stat('Completed matches', completed, Icons.verified_outlined),
          ],
        ),
        const SizedBox(height: 30),
        _section('Match schedule', () => navigate(1), 'View all'),
        if (matches.isEmpty)
          _empty(
            'No matches yet',
            'Add your first match and invite the team.',
            Icons.sports_soccer_outlined,
          )
        else
          ...matches.take(4).map(_matchCard),
      ],
    );
  }

  Widget _stat(String label, int value, IconData icon) => SizedBox(
    width: MediaQuery.sizeOf(context).width >= 850
        ? 220
        : (MediaQuery.sizeOf(context).width - 56) / 2,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: forest),
            const SizedBox(height: 15),
            Text(
              '$value',
              style: const TextStyle(
                fontSize: 30,
                color: forest,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(label, style: const TextStyle(color: Color(0xFF6F7F75))),
          ],
        ),
      ),
    ),
  );

  Widget _section(String title, VoidCallback? action, String actionLabel) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: forest,
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (action != null)
              TextButton(onPressed: action, child: Text(actionLabel)),
          ],
        ),
      );

  Widget _empty(String title, String subtitle, IconData icon) => Card(
    child: SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(38),
        child: Column(
          children: [
            Icon(icon, size: 38, color: const Color(0xFF83A28B)),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: forest,
              ),
            ),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF687970)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _matches() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading(
        'Plan the season',
        'Matches',
        '${matches.length} matches on your board',
        action: FilledButton.icon(
          onPressed: () => _editMatch(),
          icon: const Icon(Icons.add),
          label: const Text('Add match'),
        ),
      ),
      if (matches.isEmpty)
        _empty(
          'No matches yet',
          'Plan a match to start organizing.',
          Icons.event_outlined,
        )
      else
        ...matches.map(_matchCard),
    ],
  );

  Widget _matchCard(TeamMatch match) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showMatch(match.id),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF3E7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.sports_soccer, color: forest),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.title,
                    style: const TextStyle(
                      color: forest,
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${match.kickoff}  •  ${match.location}',
                    style: const TextStyle(color: Color(0xFF687970)),
                  ),
                ],
              ),
            ),
            if (match.done)
              const Chip(label: Text('Done'))
            else
              const Icon(Icons.chevron_right, color: forest),
          ],
        ),
      ),
    ),
  );

  Widget _players() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading(
        'The squad',
        'Players & parents',
        '${players.length} players in your team',
        action: FilledButton.icon(
          onPressed: () => _editPlayer(),
          icon: const Icon(Icons.person_add_outlined),
          label: const Text('Add player'),
        ),
      ),
      if (players.isEmpty)
        _empty(
          'No players yet',
          'Add your players and parent names.',
          Icons.groups_outlined,
        )
      else
        Card(
          child: Column(
            children: players
                .map(
                  (player) => Column(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 6,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFEAF3E7),
                          child: Text(
                            player.name[0].toUpperCase(),
                            style: const TextStyle(
                              color: forest,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          player.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          player.parent.isEmpty
                              ? 'No parent name'
                              : player.parent,
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) => value == 'edit'
                              ? _editPlayer(player)
                              : _deletePlayer(player),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        ),
                      ),
                      if (player != players.last) const Divider(height: 1),
                    ],
                  ),
                )
                .toList(),
          ),
        ),
    ],
  );

  Future<void> _editPlayer([Player? player]) async {
    final name = TextEditingController(text: player?.name);
    final parent = TextEditingController(text: player?.parent);
    final key = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(player == null ? 'Add player' : 'Edit player'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: key,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Player name'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a player name'
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: parent,
                  decoration: const InputDecoration(
                    labelText: 'Parent name (optional)',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, key.currentState!.validate()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      if (player == null) {
        await widget.store.addPlayer(name.text.trim(), parent.text.trim());
      } else {
        await widget.store.updatePlayer(
          player.id,
          name.text.trim(),
          parent.text.trim(),
        );
      }
      await refresh();
    }
    name.dispose();
    parent.dispose();
  }

  Future<void> _deletePlayer(Player player) async {
    if (await _confirm(
      'Delete ${player.name}?',
      'Their attendance answers will be removed and assigned duties become unassigned.',
    )) {
      await widget.store.deletePlayer(player.id);
      await refresh();
    }
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _editMatch([TeamMatch? match]) async {
    final title = TextEditingController(text: match?.title);
    final location = TextEditingController(text: match?.location);
    DateTime kickoff =
        DateTime.tryParse(match?.kickoff ?? '') ??
        DateTime.now().add(const Duration(days: 7));
    DateTime meet =
        DateTime.tryParse(match?.meet ?? '') ??
        kickoff.subtract(const Duration(minutes: 30));
    DateTime deadline =
        DateTime.tryParse(match?.deadline ?? '') ??
        kickoff.subtract(const Duration(days: 2));
    final key = GlobalKey<FormState>();
    Future<DateTime?> pick(BuildContext context, DateTime initial) async {
      final date = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
      );
      if (date == null || !context.mounted) return null;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initial),
      );
      if (time == null) return null;
      return DateTime(date.year, date.month, date.day, time.hour, time.minute);
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(match == null ? 'Add match' : 'Edit match'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Form(
                key: key,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: title,
                      decoration: const InputDecoration(
                        labelText: 'Opponent / match title',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter a title'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: location,
                      decoration: const InputDecoration(labelText: 'Location'),
                    ),
                    const SizedBox(height: 12),
                    _dateTile('Kickoff', kickoff, () async {
                      final value = await pick(context, kickoff);
                      if (value != null) setDialogState(() => kickoff = value);
                    }),
                    _dateTile('Meetup', meet, () async {
                      final value = await pick(context, meet);
                      if (value != null) setDialogState(() => meet = value);
                    }),
                    _dateTile('Reply deadline', deadline, () async {
                      final value = await pick(context, deadline);
                      if (value != null) setDialogState(() => deadline = value);
                    }),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, key.currentState!.validate()),
              child: const Text('Save match'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      final args = (
        title: title.text.trim(),
        kickoff: dateFormat.format(kickoff),
        meet: dateFormat.format(meet),
        location: location.text.trim(),
        deadline: dateFormat.format(deadline),
      );
      if (match == null) {
        final id = await widget.store.addMatch(
          title: args.title,
          kickoff: args.kickoff,
          meet: args.meet,
          location: args.location,
          deadline: args.deadline,
        );
        await refresh();
        showMatch(id);
      } else {
        await widget.store.updateMatch(
          match.id,
          title: args.title,
          kickoff: args.kickoff,
          meet: args.meet,
          location: args.location,
          deadline: args.deadline,
        );
        await refresh();
      }
    }
    title.dispose();
    location.dispose();
  }

  Widget _dateTile(String label, DateTime value, VoidCallback onTap) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.calendar_month_outlined),
        title: Text(label),
        subtitle: Text(dateFormat.format(value)),
        trailing: const Icon(Icons.edit_outlined, size: 18),
        onTap: onTap,
      );

  Future<void> _editResult(TeamMatch match) async {
    final ours = TextEditingController(text: match.rkavicScore?.toString());
    final theirs = TextEditingController(text: match.opponentScore?.toString());
    bool done = match.done;
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Result & status'),
          content: SizedBox(
            width: 390,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(match.title),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ours,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'RKAVIC goals',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: theirs,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Opponent goals',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: done,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Match done'),
                  onChanged: (value) =>
                      setDialogState(() => done = value ?? false),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Text(
                  'Leave both scores empty if there is no result yet.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF687970)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final a = ours.text.trim();
                final b = theirs.text.trim();
                if ((a.isEmpty != b.isEmpty) ||
                    (a.isNotEmpty &&
                        (int.tryParse(a) == null || int.tryParse(b) == null))) {
                  setDialogState(
                    () => error = 'Enter both scores, or leave both empty.',
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await widget.store.setResult(
        match.id,
        int.tryParse(ours.text),
        int.tryParse(theirs.text),
        done,
      );
      await refresh();
    }
    ours.dispose();
    theirs.dispose();
  }

  Widget _matchDetail(TeamMatch match) => FutureBuilder(
    future: Future.wait([
      widget.store.attendance(match.id),
      widget.store.duties(match.id),
    ]),
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final attendance = snapshot.data![0] as Map<int, int>;
      final duties = snapshot.data![1] as List<Duty>;
      final coming = players.where((p) => attendance[p.id] == 1).length;
      final absent = players.where((p) => attendance[p.id] == 2).length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: () => navigate(1),
            icon: const Icon(Icons.arrow_back),
            label: const Text('All matches'),
          ),
          const SizedBox(height: 8),
          _heading(
            match.done ? 'Completed match' : 'Match day',
            match.title,
            '${match.kickoff}  •  ${match.location}',
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: () => _editMatch(match),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit match'),
              ),
              OutlinedButton.icon(
                onPressed: () => _editResult(match),
                icon: const Icon(Icons.scoreboard_outlined),
                label: const Text('Result & status'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  if (await _confirm(
                    'Delete this match?',
                    'Attendance and duties for this match will also be removed.',
                  )) {
                    await widget.store.deleteMatch(match.id);
                    selectedMatchId = null;
                    await refresh();
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _infoCard('KICKOFF', match.kickoff, Icons.event_outlined),
              _infoCard('MEET AT', match.meet, Icons.schedule_outlined),
              _infoCard(
                'REPLY BY',
                match.deadline,
                Icons.mark_email_read_outlined,
              ),
              _infoCard('RESULT', match.result, Icons.emoji_events_outlined),
            ],
          ),
          const SizedBox(height: 28),
          _section('Attendance', null, ''),
          Text(
            '$coming coming  •  $absent absent  •  ${players.length - coming - absent} awaiting reply',
            style: const TextStyle(color: Color(0xFF687970)),
          ),
          const SizedBox(height: 12),
          if (players.isEmpty)
            _empty(
              'No players yet',
              'Add players to track attendance.',
              Icons.groups_outlined,
            )
          else
            Card(
              child: Column(
                children: players
                    .map(
                      (p) => ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFEAF3E7),
                          child: Text(
                            p.name[0].toUpperCase(),
                            style: const TextStyle(color: forest),
                          ),
                        ),
                        title: Text(p.name),
                        subtitle: Text(
                          p.parent.isEmpty ? 'Parent not set' : p.parent,
                        ),
                        trailing: DropdownButton<int>(
                          value: attendance[p.id] ?? 0,
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('Awaiting')),
                            DropdownMenuItem(value: 1, child: Text('Coming')),
                            DropdownMenuItem(value: 2, child: Text('Absent')),
                          ],
                          onChanged: (value) async {
                            await widget.store.setAttendance(
                              match.id,
                              p.id,
                              value ?? 0,
                            );
                            setState(() {});
                          },
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          const SizedBox(height: 28),
          _section('Match duties', () => _addDuty(match.id), 'Add duty'),
          if (duties.isEmpty)
            _empty(
              'No duties yet',
              'Add duties and assign a parent or player.',
              Icons.task_alt_outlined,
            )
          else
            Card(
              child: Column(
                children: duties
                    .map(
                      (duty) => ListTile(
                        leading: Checkbox(
                          value: duty.done,
                          onChanged: (value) async {
                            await widget.store.setDutyDone(
                              duty.id,
                              value ?? false,
                            );
                            setState(() {});
                          },
                        ),
                        title: Text(
                          duty.title,
                          style: TextStyle(
                            decoration: duty.done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          players
                                  .where((p) => p.id == duty.playerId)
                                  .map(
                                    (p) => p.parent.isEmpty
                                        ? p.name
                                        : '${p.parent} (${p.name})',
                                  )
                                  .firstOrNull ??
                              'Unassigned',
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'assign') {
                              await _assignDuty(duty);
                            }
                            if (value == 'delete') {
                              await widget.store.deleteDuty(duty.id);
                              setState(() {});
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'assign',
                              child: Text('Assign'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          const SizedBox(height: 28),
          _section('WhatsApp drafts', null, ''),
          const Text(
            'Review a draft, then share it yourself.',
            style: TextStyle(color: Color(0xFF687970)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _draftButton(
                'Invitation',
                Icons.send_outlined,
                invitationDraft(match),
              ),
              _draftButton(
                'Reminder',
                Icons.notifications_outlined,
                reminderDraft(match, players, attendance),
              ),
              _draftButton(
                'Duties',
                Icons.assignment_outlined,
                dutiesDraft(match, players, duties),
              ),
              _draftButton(
                'Substitutes',
                Icons.person_search_outlined,
                substitutesDraft(match),
              ),
            ],
          ),
          const SizedBox(height: 28),
        ],
      );
    },
  );

  Widget _infoCard(String label, String value, IconData icon) => SizedBox(
    width: MediaQuery.sizeOf(context).width >= 850
        ? 225
        : (MediaQuery.sizeOf(context).width - 56) / 2,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: forest),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF6C8575),
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              value,
              style: const TextStyle(
                color: forest,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _addDuty(int matchId) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add duty'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Duty, e.g. field setup',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty) {
      await widget.store.addDuty(matchId, value);
      setState(() {});
    }
    controller.dispose();
  }

  Future<void> _assignDuty(Duty duty) async {
    final value = await showDialog<int?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Assign ${duty.title}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, -1),
            child: const Text('Unassigned'),
          ),
          ...players.map(
            (p) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p.id),
              child: Text(
                p.parent.isEmpty ? p.name : '${p.parent} (${p.name})',
              ),
            ),
          ),
        ],
      ),
    );
    if (value != null) {
      await widget.store.assignDuty(duty.id, value == -1 ? null : value);
      setState(() {});
    }
  }

  Widget _draftButton(String label, IconData icon, String draft) =>
      OutlinedButton.icon(
        onPressed: () => _showDraft(label, draft),
        icon: Icon(icon),
        label: Text(label),
      );

  Future<void> _showDraft(String label, String draft) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label draft'),
        content: SizedBox(width: 490, child: SelectableText(draft)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: draft));
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
          FilledButton.icon(
            onPressed: () async {
              if (Platform.isWindows) {
                await Clipboard.setData(ClipboardData(text: draft));
                await launchUrl(
                  Uri.parse('https://web.whatsapp.com/'),
                  mode: LaunchMode.externalApplication,
                );
              } else {
                await SharePlus.instance.share(ShareParams(text: draft));
              }
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.share_outlined),
            label: Text(
              Platform.isWindows ? 'Copy & open WhatsApp Web' : 'Share',
            ),
          ),
        ],
      ),
    );
  }
}
