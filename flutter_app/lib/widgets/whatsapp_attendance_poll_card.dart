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
  });

  final TeamStore store;
  final TeamMatch match;

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
      await _refreshLink();
      if (mounted)
        setState(() => _status = 'Attendance poll linked on this device.');
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
