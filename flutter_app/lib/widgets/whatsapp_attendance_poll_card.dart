import 'dart:io';

import 'package:flutter/material.dart';

import '../data/team_store.dart';
import '../data/whatsapp_message_reader.dart';
import '../data/whatsapp_message_reader_factory.dart';

class WhatsAppAttendancePollCard extends StatefulWidget {
  const WhatsAppAttendancePollCard({
    super.key,
    required this.store,
    required this.match,
    required this.onAttendanceChanged,
  });

  final TeamStore store;
  final TeamMatch match;
  final VoidCallback onAttendanceChanged;

  @override
  State<WhatsAppAttendancePollCard> createState() =>
      _WhatsAppAttendancePollCardState();
}

class _WhatsAppAttendancePollCardState
    extends State<WhatsAppAttendancePollCard> {
  AttendancePollLink? _link;
  List<WhatsAppPollSnapshot> _polls = [];
  String? _status;
  bool _loading = true;
  bool _loadingPolls = false;

  @override
  void initState() {
    super.initState();
    _refreshLink();
  }

  Future<void> _refreshLink() async {
    final link = await widget.store.attendancePollLink(widget.match.id);
    if (!mounted) return;
    setState(() {
      _link = link;
      _loading = false;
    });
  }

  Future<void> _findPolls() async {
    setState(() {
      _loadingPolls = true;
      _status = null;
    });
    try {
      final polls = await createWhatsAppMessageReader().availablePolls();
      if (!mounted) return;
      setState(() {
        _polls = polls;
        _status = polls.isEmpty
            ? Platform.isAndroid
                  ? 'No polls are cached for the selected Android linked-device group. Connect the structured poll reader and select a group in Settings first.'
                  : 'No polls are cached for the selected group. Start the WhatsApp companion and choose the group first.'
            : '${polls.length} poll(s) found in the selected group cache.';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not load polls: $error');
    } finally {
      if (mounted) setState(() => _loadingPolls = false);
    }
  }

  Future<void> _linkPoll() async {
    if (_polls.isEmpty) await _findPolls();
    if (!mounted) return;
    final poll = await showDialog<WhatsAppPollSnapshot>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose attendance poll'),
        content: SizedBox(
          width: 560,
          child: _polls.isEmpty
              ? Text(_status ?? 'No polls are available.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: _polls.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final poll = _polls[index];
                    final choices = poll.options.join(' · ');
                    final votes = poll.votes
                        .map(
                          (vote) => '${vote.voter}: ${vote.options.join(', ')}',
                        )
                        .join('\n');
                    return ListTile(
                      title: Text(poll.question),
                      subtitle: Text(
                        [
                          if (poll.createdAt != null)
                            'Created ${poll.createdAt!.toLocal()}',
                          if (choices.isNotEmpty) 'Choices: $choices',
                          if (votes.isNotEmpty) 'Current votes:\n$votes',
                        ].join('\n'),
                      ),
                      isThreeLine: true,
                      onTap: () => Navigator.pop(context, poll),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (poll == null || !mounted) return;
    final replacing = _link != null && _link!.pollId != poll.id;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          replacing ? 'Replace active attendance poll?' : 'Link poll to match?',
        ),
        content: Text(
          'Match: ${widget.match.title}\n\nPoll: ${poll.question}\n\nChoices: ${poll.options.join(', ')}\n\nOnly this poll will be treated as this match’s attendance poll. Poll text and identifiers stay on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(replacing ? 'Replace poll' : 'Link poll'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await widget.store.linkAttendancePoll(
        AttendancePollLink(
          matchId: widget.match.id,
          groupId: poll.groupId,
          pollId: poll.id,
          question: poll.question,
          options: poll.options,
          linkedAt: DateTime.now().toUtc(),
        ),
      );
      final changed = await widget.store.applyAttendancePoll(poll);
      await _refreshLink();
      if (mounted) {
        setState(
          () => _status =
              'Attendance poll linked. Automatically updated $changed player(s) from current votes. New votes will update attendance while the reader is connected.',
        );
        widget.onAttendanceChanged();
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not link poll: $error');
    }
  }

  Future<void> _unlinkPoll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlink attendance poll?'),
        content: const Text(
          'This stops this poll from being associated with the match on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep linked'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unlink poll'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await widget.store.unlinkAttendancePoll(widget.match.id);
    await _refreshLink();
    if (mounted) setState(() => _status = 'Attendance poll unlinked.');
  }

  Future<void> _configureAttendance() async {
    final link = _link;
    if (link == null) return;
    try {
      final polls = await createWhatsAppMessageReader().availablePolls();
      final poll = polls
          .where(
            (item) => item.id == link.pollId && item.groupId == link.groupId,
          )
          .firstOrNull;
      if (!mounted) return;
      if (poll == null) {
        setState(
          () => _status = 'The linked poll is not available. Start the reader and select its WhatsApp group.',
        );
        return;
      }
      if (poll.allowMultipleAnswers == null) {
        setState(
          () => _status = 'The poll selection mode is unknown, so votes cannot be applied safely.',
        );
        return;
      }
      final players = await widget.store.players();
      final options = await widget.store.pollOptionMappings(link.matchId);
      final mappings = await widget.store.pollPlayerMappings(link.groupId);
      for (final option in poll.options) {
        final inferred = inferredPollStatus(option);
        if (inferred != null) options.putIfAbsent(option, () => inferred);
      }
      for (final vote in poll.votes.where((vote) => vote.voterId.isNotEmpty)) {
        mappings.putIfAbsent(
          vote.voterId,
          () => inferredVoterPlayers(vote.voter, players),
        );
      }
      if (!mounted) return;
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Review automatic attendance matches'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'The app selected clear answers and roster matches. Change any suggestion here:',
                    ),
                    if (poll.allowMultipleAnswers == true)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          'This poll allows multiple answers. Only voters with exactly one selected answer will update attendance.',
                        ),
                      ),
                    ...poll.options.map(
                      (option) => DropdownButtonFormField<int>(
                        initialValue: options[option],
                        decoration: InputDecoration(labelText: option),
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('Coming')),
                          DropdownMenuItem(value: 2, child: Text('Absent')),
                          DropdownMenuItem(value: 3, child: Text('Maybe')),
                        ],
                        onChanged: (value) => update(() {
                          if (value != null) options[option] = value;
                        }),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Players represented by each voter:'),
                    if (poll.votes.isEmpty)
                      const Text(
                        'No voters are available yet. Return here after a vote is received.',
                      ),
                    ...poll.votes
                        .where((vote) => vote.voterId.isNotEmpty)
                        .map(
                          (vote) => ExpansionTile(
                            title: Text(vote.voter),
                            subtitle: Text(
                              vote.options.isEmpty
                                  ? 'No current choice'
                                  : vote.options.join(', '),
                            ),
                            children: players
                                .map(
                                  (player) => CheckboxListTile(
                                    title: Text(player.name),
                                    subtitle: player.parent.isNotEmpty
                                        ? Text(player.parent)
                                        : null,
                                    value:
                                        mappings[vote.voterId]?.contains(
                                          player.id,
                                        ) ??
                                        false,
                                    onChanged: (value) => update(() {
                                      final selected = mappings.putIfAbsent(
                                        vote.voterId,
                                        () => <int>{},
                                      );
                                      if (value == true) {
                                        selected.add(player.id);
                                      } else {
                                        selected.remove(player.id);
                                      }
                                    }),
                                  ),
                                )
                                .toList(),
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
                onPressed: poll.options.every(options.containsKey)
                    ? () => Navigator.pop(context, true)
                    : null,
                child: const Text('Save and apply votes'),
              ),
            ],
          ),
        ),
      );
      if (saved != true || !mounted) return;
      await widget.store.savePollOptionMappings(link.matchId, options);
      for (final vote in poll.votes.where((vote) => vote.voterId.isNotEmpty)) {
        await widget.store.savePollPlayerMapping(
          link.groupId,
          vote.voterId,
          mappings[vote.voterId] ?? <int>{},
        );
      }
      final changed = await widget.store.applyAttendancePoll(poll);
      if (!mounted) return;
      setState(
        () => _status =
            'Attendance configured. Updated $changed player(s); unmapped voters and manual overrides are left for review.',
      );
      widget.onAttendanceChanged();
    } catch (error) {
      if (mounted)
        setState(() => _status = 'Could not configure attendance: $error');
    }
  }

  Future<void> _reapplyPoll() async {
    final link = _link;
    if (link == null) return;
    final polls = await createWhatsAppMessageReader().availablePolls();
    final poll = polls
        .where((item) => item.id == link.pollId && item.groupId == link.groupId)
        .firstOrNull;
    if (!mounted) return;
    if (poll == null || poll.allowMultipleAnswers == null) {
      setState(
        () => _status =
            'The linked poll is unavailable or its selection mode is unknown.',
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reapply poll votes?'),
        content: const Text(
          'This clears manual attendance overrides for this match and reapplies available mapped poll votes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reapply votes'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await widget.store.clearPollManualOverrides(link.matchId);
    final changed = await widget.store.applyAttendancePoll(poll);
    if (!mounted) return;
    setState(
      () => _status = 'Reapplied poll votes: updated $changed player(s).',
    );
    widget.onAttendanceChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LinearProgressIndicator();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'WhatsApp attendance poll',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (Platform.isAndroid)
              const Text(
                'Android uses the linked-device poll reader selected in Settings. Notification capture alone cannot provide poll choices or voters.',
              ),
            if (_link == null)
              const Text(
                'No attendance poll is linked to this match on this device.',
              )
            else ...[
              Text(_link!.question),
              const SizedBox(height: 4),
              Text('Choices: ${_link!.options.join(' · ')}'),
              Text('Linked ${_link!.linkedAt.toLocal()}'),
              const SizedBox(height: 4),
              const Text(
                'Clear answers and voter names are matched to the roster automatically. Use Review vote matches only for voters the app cannot identify.',
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _loadingPolls ? null : _linkPoll,
                  icon: _loadingPolls
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.poll_outlined),
                  label: Text(_link == null ? 'Link poll' : 'Change poll'),
                ),
                if (_link != null)
                  FilledButton.tonal(
                    onPressed: _configureAttendance,
                    child: const Text('Review vote matches'),
                  ),
                if (_link != null)
                  TextButton(
                    onPressed: _reapplyPoll,
                    child: const Text('Reapply votes'),
                  ),
                if (_link != null)
                  TextButton(
                    onPressed: _unlinkPoll,
                    child: const Text('Unlink'),
                  ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 6),
              Text(_status!, style: const TextStyle(color: Color(0xFF6F5B4A))),
            ],
          ],
        ),
      ),
    );
  }
}
