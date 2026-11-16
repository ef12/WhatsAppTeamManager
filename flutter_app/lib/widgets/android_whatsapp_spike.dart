import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/whatsapp_message_reader.dart';
import '../data/whatsapp_message_reader_factory.dart';
import '../data/windows_whatsapp_message_reader.dart';

class WhatsAppReaderCard extends StatefulWidget {
  const WhatsAppReaderCard({super.key});

  @override
  State<WhatsAppReaderCard> createState() => _WhatsAppReaderCardState();
}

class _WhatsAppReaderCardState extends State<WhatsAppReaderCard> {
  final _groupSearch = TextEditingController();
  final _pollPhone = TextEditingController();
  late final WhatsAppMessageReader _reader;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  final _log = <String>[];
  final _readerItems = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _groups = [];
  String? _selectedGroup;
  String? _pairingResult;
  bool _pollReaderStarted = false;
  String? _readerEmptyMessage;
  String _status = 'Checking notification access';
  bool _notificationAccess = false;
  bool _captureConsent = false;
  bool _busy = false;
  bool _windowsReaderStarted = false;
  String? _pairingQr;
  bool get _isAndroid => Platform.isAndroid;

  List<Map<String, dynamic>> get _visibleGroups {
    final query = _groupSearch.text.trim().toLowerCase();
    if (query.isEmpty) return _groups;
    return _groups
        .where(
          (group) => (group['name'] as String).toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _reader = createWhatsAppMessageReader();
    _subscription = _reader.events.listen(
      _onEvent,
      onError: (Object error) => _append('Reader event error: $error'),
    );
    if (_isAndroid) {
      _refreshNotificationAccess();
    } else {
      _windowsReaderStarted =
          (_reader as WindowsWhatsAppMessageReader).isRunning;
      _loadGroupsInternal()
          .then((_) {
            if (mounted && _windowsReaderStarted && _selectedGroup != null) {
              _readHistory('today');
            }
          })
          .catchError(
            (Object error) => _append('Could not load groups: $error'),
          );
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    _groupSearch.dispose();
    _pollPhone.dispose();
    super.dispose();
  }

  Future<void> _refreshNotificationAccess() async {
    try {
      final authorization = _reader as WhatsAppReaderAuthorization;
      final enabled = await authorization.hasNotificationAccess();
      final consent = await authorization.hasCaptureConsent();
      if (!mounted) return;
      setState(() {
        _notificationAccess = enabled;
        _captureConsent = consent;
        _status = !enabled
            ? 'Access required'
            : consent
            ? 'Capturing selected group notifications'
            : 'Choose a group, then start capture';
      });
    } on PlatformException catch (error) {
      _append(error.message ?? error.code);
    }
  }

  void _append(String value) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, value);
      if (_log.length > 30) _log.removeLast();
    });
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'pairing_qr') {
      setState(() {
        _pairingQr = event['qr'] as String?;
        _status = 'Scan the QR code with WhatsApp Linked devices';
      });
      return;
    }
    if (type == 'groups_loaded') {
      setState(() {
        _pairingQr = null;
        _status = 'WhatsApp linked; ${event['count']} group(s) loaded';
      });
      _append('WhatsApp returned ${event['count']} joined group(s).');
      _loadGroupsInternal();
      return;
    }
    if (type == 'groups_error') {
      setState(() {
        _pairingQr = null;
        _status = 'Could not load WhatsApp groups: ${event['message']}';
      });
      return;
    }
    if (type == 'reader_starting') {
      setState(() => _status = 'Starting WhatsApp connection…');
      return;
    }
    if (type == 'authenticated') {
      setState(() => _status = 'WhatsApp linked; loading groups…');
      return;
    }
    if (type == 'reader_ready') {
      setState(() {
        _pairingQr = null;
        _status = 'WhatsApp reader connected';
      });
      return;
    }
    if (type == 'group_selected') {
      setState(() {
        _selectedGroup = event['id'] as String?;
        _readerItems.clear();
        _readerEmptyMessage = null;
        _status = 'Reading ${event['name']}';
      });
      _append('Reader switched to ${event['name']}.');
      return;
    }
    if (type == 'history_updated') {
      if (event['groupId'] == _selectedGroup) {
        _reader
            .readToday()
            .then((result) {
              if (mounted && event['groupId'] == _selectedGroup)
                _onEvent(result.json);
            })
            .catchError(
              (Object error) => _append('Could not read messages: $error'),
            );
      }
      return;
    }
    if (type == 'companion_log' || type == 'companion_error') {
      final line = event['text']?.toString() ?? '';
      if (line.isNotEmpty) _append(line);
      return;
    }
    if (type == 'auth_failure' || type == 'disconnected') {
      setState(
        () => _status =
            'WhatsApp disconnected: ${event['reason'] ?? event['message'] ?? 'authentication failed'}',
      );
      _append(const JsonEncoder.withIndent('  ').convert(event));
      return;
    }
    if (type == 'companion_exit') {
      setState(() {
        _windowsReaderStarted = false;
        _status = 'WhatsApp reader stopped (exit ${event['code']})';
      });
      return;
    }
    if (type == 'connected') {
      _append('Linked-device session connected; loading all joined groups.');
      if (_isAndroid && _pollReaderStarted) _run(_loadGroupsInternal);
      return;
    }
    if (type == 'reader_access') {
      final enabled = event['enabled'] == true;
      setState(() {
        _notificationAccess = enabled;
        _status = !enabled
            ? 'Access required'
            : _captureConsent
            ? 'Capturing selected group notifications'
            : 'Choose a group, then start capture';
      });
      if (enabled) _append('WhatsApp notification access enabled.');
      return;
    }
    if (type == 'history_result') {
      final messages = (event['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      setState(() {
        _readerItems
          ..clear()
          ..addAll(messages);
        _readerEmptyMessage = messages.isEmpty
            ? event['error'] as String?
            : null;
      });
      _append(
        event['error'] as String? ?? 'Loaded ${messages.length} message(s).',
      );
      return;
    }
    if (type == 'reader_message') {
      final message = event['message'];
      if (message is Map<String, dynamic>) _upsertReaderMessage(message);
      return;
    }
    _append(const JsonEncoder.withIndent('  ').convert(event));
  }

  void _upsertReaderMessage(Map<String, dynamic> message) {
    final id = message['id'] as String?;
    if (id == null || message['chat'] != _selectedGroup) return;
    setState(() {
      _readerEmptyMessage = null;
      final index = _readerItems.indexWhere((item) => item['id'] == id);
      if (index == -1) {
        _readerItems.insert(0, message);
      } else {
        _readerItems[index] = message;
      }
      if (_readerItems.length > 200) _readerItems.removeLast();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on PlatformException catch (error) {
      _append(error.message ?? error.code);
    } catch (error) {
      _append('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() => _run(() async {
    if (!_isAndroid) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start WhatsApp group reader?'),
          content: const Text(
            'The app will start its WhatsApp connection, show the pairing QR here if needed, and store selected-group messages and polls on this PC for 30 days. Confirm that group members have been informed about capture.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Members informed; start reader'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      await _reader.start();
      setState(() {
        _windowsReaderStarted = true;
        _pairingQr = null;
        _status = 'Starting WhatsApp reader…';
      });
      return;
    }
    final authorization = _reader as WhatsAppReaderAuthorization;
    final accessEnabled = await authorization.hasNotificationAccess();
    if (!accessEnabled) {
      await _reader.start();
      setState(() {
        _notificationAccess = false;
        _status = 'Enable access in Android Settings';
      });
      return;
    }
    if (_selectedGroup == null) {
      setState(() => _status = 'Select a group before starting capture');
      _append(
        'Select one group first; other groups will not have message text saved.',
      );
      return;
    }
    if (!await authorization.hasCaptureConsent()) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start WhatsApp group capture?'),
          content: Text(
            'The app will save readable notification text only for "${_groups.firstWhere((group) => group['id'] == _selectedGroup)['name']}" on this device for up to 30 days. Other groups are used only to show their names for selection. No media is saved or uploaded. Confirm that this group has been informed about capture.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Group is informed; start'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      await authorization.setCaptureConsent(true);
    }
    await _reader.start();
    setState(() {
      _notificationAccess = true;
      _captureConsent = true;
      _status = 'Capturing selected group notifications';
    });
    await _loadGroupsInternal();
  });

  Future<void> _openNotificationSettings() => _run(() async {
    await (_reader as WhatsAppReaderAuthorization)
        .openNotificationAccessSettings();
  });

  Future<void> _loadGroupsInternal() async {
    final groups = await _reader.loadGroups();
    final decoded = groups.map((group) => group.toJson()).toList();
    setState(() {
      _groups = decoded;
      _status = !_notificationAccess && _isAndroid
          ? 'Access required'
          : _groups.isEmpty
          ? _isAndroid
                ? _pollReaderStarted
                      ? 'No linked groups loaded. Pair the account or refresh.'
                      : 'Connect the linked-device reader to load all WhatsApp groups.'
                : 'Start the reader to load your WhatsApp groups'
          : (!_isAndroid || _pollReaderStarted)
          ? '${_groups.length} WhatsApp group(s) available'
          : '${_groups.length} notification-observed group(s)';
      if (!_groups.any((group) => group['id'] == _selectedGroup)) {
        _selectedGroup = _groups
            .where((group) => group['selected'] == true)
            .map((group) => group['id'] as String)
            .firstOrNull;
      }
    });
  }

  Future<void> _loadGroups() => _run(_loadGroupsInternal);

  Future<void> _startPollReader() => _run(() async {
    final pollReader = _reader as WhatsAppStructuredPollReader;
    await pollReader.startPollReader();
    setState(() => _pollReaderStarted = true);
    await _loadGroupsInternal();
    if (_groups.isEmpty && _pollPhone.text.trim().isNotEmpty) {
      final response = await pollReader.pairPollReader(_pollPhone.text.trim());
      setState(() => _pairingResult = response);
      await _loadGroupsInternal();
    } else if (_groups.isEmpty) {
      setState(() {
        _pairingResult = 'No WhatsApp account is linked to this app yet. Enter the account phone number with country code, then tap Connect poll reader to pair it.';
      });
    }
  });

  Future<void> _stopCapture() => _run(() async {
    await _reader.stop();
    setState(() {
      _captureConsent = false;
      _readerItems.clear();
      _readerEmptyMessage = null;
      _status = 'Capture stopped; local messages cleared';
    });
    _append('Capture stopped and cached message text erased.');
  });

  Future<void> _stopWindowsReader() => _run(() async {
    await _reader.stop();
    setState(() {
      _windowsReaderStarted = false;
      _pairingQr = null;
      _status = 'WhatsApp reader stopped';
    });
  });

  Future<void> _selectGroup(String? groupId) async {
    if (groupId == null) return;
    await _run(() async {
      await _reader.selectGroup(groupId);
      final consent = _isAndroid
          ? await (_reader as WhatsAppReaderAuthorization).hasCaptureConsent()
          : false;
      setState(() {
        _selectedGroup = groupId;
        _captureConsent = consent;
        _groupSearch.clear();
        _readerItems.clear();
        _readerEmptyMessage = null;
        if (_isAndroid && !consent) {
          _status = 'Selected group; start capture to confirm notice';
        }
      });
      _append(
        'Selected group ${_groups.firstWhere((g) => g['id'] == groupId)['name']}',
      );
    });
  }

  Future<void> _readHistory(String mode) => _run(() async {
    if (_selectedGroup == null) {
      _append('Select a group before reading messages.');
      return;
    }
    final result = mode == 'today'
        ? await _reader.readToday()
        : await _reader.readLatest();
    _onEvent(result.json);
  });

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.phonelink_ring_outlined,
            color: Color(0xFF2E6B45),
            size: 32,
          ),
          const SizedBox(height: 12),
          Text(
            _isAndroid ? 'Android WhatsApp reader' : 'Windows WhatsApp reader',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text('Status: $_status'),
          const SizedBox(height: 8),
          Text(
            _isAndroid
                ? 'Notification capture only discovers groups after a readable notification arrives. Connect the linked-device reader below to load your full joined-group list and read structured polls.'
                : 'Start the WhatsApp reader here. The app manages the connection and lists all groups available to the linked account.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_isAndroid)
                FilledButton(
                  onPressed: _busy ? null : _openNotificationSettings,
                  child: Text(
                    _notificationAccess
                        ? 'Notification access settings'
                        : 'Enable notification access',
                  ),
                ),
              if (_isAndroid)
                OutlinedButton(
                  onPressed: _busy ? null : _start,
                  child: const Text('Start capture'),
                ),
              if (_isAndroid && _captureConsent)
                TextButton(
                  onPressed: _busy ? null : _stopCapture,
                  child: const Text('Stop and clear messages'),
                ),
              OutlinedButton(
                onPressed: _busy ? null : _loadGroups,
                child: Text(
                  _isAndroid
                      ? (_pollReaderStarted
                            ? 'Refresh WhatsApp groups'
                            : 'Refresh observed groups')
                      : 'Refresh groups',
                ),
              ),
              if (!_isAndroid)
                FilledButton.icon(
                  onPressed: _busy || _windowsReaderStarted ? null : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(
                    _windowsReaderStarted
                        ? 'Reader running'
                        : 'Start WhatsApp reader',
                  ),
                ),
              if (!_isAndroid && _windowsReaderStarted)
                TextButton(
                  onPressed: _busy ? null : _stopWindowsReader,
                  child: const Text('Stop reader'),
                ),
            ],
          ),
          if (_pairingQr != null) ...[
            const SizedBox(height: 16),
            const Text(
              'On your phone, open WhatsApp → Linked devices → Link a device.',
            ),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: _pairingQr!, size: 240),
              ),
            ),
          ],
          if (_isAndroid) ...[
            const SizedBox(height: 18),
            const Divider(),
            const Text(
              'Structured polls and voter names',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'This uses a separate WhatsApp linked-device session. It receives structured poll votes and works with the attendance poll linker. In WhatsApp, open Linked devices to link this app.',
            ),
            TextField(
              controller: _pollPhone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'WhatsApp phone number with country code',
                hintText: '31612345678',
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy ? null : _startPollReader,
                  child: Text(
                    _pollReaderStarted
                        ? 'Reconnect poll reader'
                        : 'Connect poll reader',
                  ),
                ),
                if (_pollReaderStarted)
                  OutlinedButton(
                    onPressed: _busy ? null : _loadGroups,
                    child: const Text('Refresh WhatsApp groups'),
                  ),
              ],
            ),
            if (_pairingResult != null)
              SelectableText(
                _pairingResult!.length == 8
                    ? 'Pairing code: $_pairingResult\nOn the WhatsApp account, open Linked devices → Link a device → Link with phone number and enter this code.'
                    : _pairingResult!,
              ),
          ],
          if (!_isAndroid && _groups.isEmpty) ...[
            const SizedBox(height: 14),
            const Text('Select a WhatsApp group to read:'),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: 'WhatsApp group',
                helperText: 'Groups appear here after WhatsApp connects.',
              ),
              items: const [],
              onChanged: null,
            ),
          ],
          if (_groups.isEmpty && _isAndroid && _notificationAccess) ...[
            const SizedBox(height: 12),
            const Text(
              'This is not the full WhatsApp list. Groups appear here only after a readable notification; connect the linked-device reader above to choose any joined group.',
            ),
          ],
          if (_groups.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              _isAndroid && !_pollReaderStarted
                  ? 'Notification-observed groups (incomplete list):'
                  : 'Select a WhatsApp group to read:',
            ),
            TextField(
              controller: _groupSearch,
              decoration: const InputDecoration(
                labelText: 'Find a group',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'WhatsApp group'),
              initialValue:
                  _visibleGroups.any((group) => group['id'] == _selectedGroup)
                  ? _selectedGroup
                  : null,
              isExpanded: true,
              menuMaxHeight: 480,
              selectedItemBuilder: (context) => _visibleGroups
                  .map(
                    (group) => Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        group['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              items: _visibleGroups
                  .map(
                    (group) => DropdownMenuItem<String>(
                      value: group['id'] as String,
                      child: Text(
                        group['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _selectGroup,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy || _selectedGroup == null
                      ? null
                      : () => _readHistory('today'),
                  child: Text(
                    _isAndroid && !_pollReaderStarted
                        ? "Read today's captured messages"
                        : "Read today's messages and polls",
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _busy || _selectedGroup == null
                      ? null
                      : () => _readHistory('latest'),
                  child: Text(
                    _isAndroid && !_pollReaderStarted
                        ? 'Read latest captured message'
                        : 'Read latest + poll votes',
                  ),
                ),
              ],
            ),
          ],
          if (_readerItems.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Captured messages',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._readerItems.map(_buildReaderItem),
          ],
          if (_readerEmptyMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_readerEmptyMessage!),
            ),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Reader events'),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: const Color(0xFFF5F0E9),
              child: SingleChildScrollView(
                child: SelectableText(_log.join('\n')),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _buildReaderItem(Map<String, dynamic> item) {
    final timestamp = DateTime.tryParse(item['timestamp'] as String? ?? '')
        ?.toLocal();
    final dateLabel = timestamp == null
        ? ''
        : '${timestamp.day.toString().padLeft(2, '0')}/${timestamp.month.toString().padLeft(2, '0')} ${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    final poll = item['kind'] == 'poll'
        ? WhatsAppPollSnapshot.fromJson(item)
        : null;
    final reactions = (item['reactions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${item['sender'] ?? 'Member'} · $dateLabel',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text('${item['text'] ?? ''}'),
            if (poll != null) ...[
              const SizedBox(height: 6),
              ...poll.options.map((option) => Text('• $option')),
              const SizedBox(height: 6),
              if (poll.votes.isEmpty)
                const Text('No votes available yet')
              else
                ...poll.votes.map(
                  (vote) => Text(
                    '${vote.voter}: ${vote.options.isEmpty ? '(vote cleared)' : vote.options.join(', ')}',
                  ),
                ),
            ],
            if (reactions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                reactions
                    .map(
                      (reaction) =>
                          '${reaction['emoji'] ?? ''} ${reaction['sender'] ?? 'Member'}',
                    )
                    .join('  '),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
