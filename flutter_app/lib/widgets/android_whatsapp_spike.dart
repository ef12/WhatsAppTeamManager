import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/whatsapp_message_reader.dart';
import '../data/whatsapp_message_reader_factory.dart';

class WhatsAppReaderCard extends StatefulWidget {
  const WhatsAppReaderCard({super.key});

  @override
  State<WhatsAppReaderCard> createState() => _WhatsAppReaderCardState();
}

class _WhatsAppReaderCardState extends State<WhatsAppReaderCard> {
  final _groupSearch = TextEditingController();
  late final WhatsAppMessageReader _reader;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  final _log = <String>[];
  final _readerItems = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _groups = [];
  String? _selectedGroup;
  String? _readerEmptyMessage;
  String _status = 'Checking notification access';
  bool _notificationAccess = false;
  bool _busy = false;
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
    if (_isAndroid) _refreshNotificationAccess();
  }

  @override
  void dispose() {
    _subscription.cancel();
    _groupSearch.dispose();
    super.dispose();
  }

  Future<void> _refreshNotificationAccess() async {
    try {
      final enabled = await (_reader as WhatsAppReaderAuthorization)
          .hasNotificationAccess();
      if (!mounted) return;
      setState(() {
        _notificationAccess = enabled;
        _status = enabled
            ? 'Capturing WhatsApp notifications'
            : 'Access required';
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
    if (type == 'reader_access') {
      final enabled = event['enabled'] == true;
      setState(() {
        _notificationAccess = enabled;
        _status = enabled
            ? 'Capturing WhatsApp notifications'
            : 'Access required';
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
    await _reader.start();
    final enabled = _isAndroid
        ? await (_reader as WhatsAppReaderAuthorization).hasNotificationAccess()
        : false;
    setState(() {
      _notificationAccess = enabled;
      _status = _isAndroid
          ? enabled
                ? 'Capturing WhatsApp notifications'
                : 'Enable access in Android Settings'
          : 'Windows cache ready';
    });
    if (enabled) await _loadGroupsInternal();
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
                ? 'Waiting for WhatsApp messages'
                : 'No saved group'
          : '${_groups.length} group(s) with captured messages';
      if (!_groups.any((group) => group['id'] == _selectedGroup)) {
        _selectedGroup = null;
      }
    });
  }

  Future<void> _loadGroups() => _run(_loadGroupsInternal);

  Future<void> _selectGroup(String? groupId) async {
    if (groupId == null) return;
    await _run(() async {
      await _reader.selectGroup(groupId);
      setState(() {
        _selectedGroup = groupId;
        _groupSearch.clear();
        _readerItems.clear();
        _readerEmptyMessage = null;
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
                ? 'Reads message text from WhatsApp notifications on this device. Enable notification previews in WhatsApp. Android does not expose old chat history or complete poll voter details to other apps.'
                : 'Run companion/start-companion.cmd on this PC. This screen reads messages fetched by the Windows companion.',
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
                  child: const Text('Start reader'),
                ),
              OutlinedButton(
                onPressed: _busy ? null : _loadGroups,
                child: Text(
                  _isAndroid ? 'Refresh captured groups' : 'Refresh group',
                ),
              ),
            ],
          ),
          if (_groups.isEmpty && _isAndroid && _notificationAccess) ...[
            const SizedBox(height: 12),
            const Text(
              'New groups appear here after WhatsApp posts a readable message notification.',
            ),
          ],
          if (_groups.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Select a group to view captured messages:'),
            TextField(
              controller: _groupSearch,
              decoration: const InputDecoration(
                labelText: 'Find a group',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String>(
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
                    _isAndroid
                        ? "Read today's captured messages"
                        : "Read today's messages and polls",
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _busy || _selectedGroup == null
                      ? null
                      : () => _readHistory('latest'),
                  child: Text(
                    _isAndroid
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
          ],
        ),
      ),
    );
  }
}
