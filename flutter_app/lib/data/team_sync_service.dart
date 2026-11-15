import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'team_backup.dart';
import 'team_merge.dart';
import 'team_store.dart';

class RemoteTeamSnapshot {
  const RemoteTeamSnapshot({required this.revision, required this.payload});

  final int revision;
  final String payload;

  TeamBackup get backup => TeamBackup.fromJsonString(payload);
}

class TeamMember {
  const TeamMember(this.userId, this.name);
  final String userId;
  final String name;
}

class SyncConflict {
  const SyncConflict({
    required this.localRevision,
    required this.remoteSnapshot,
    this.merge,
  });

  final int localRevision;
  final RemoteTeamSnapshot? remoteSnapshot;
  final TeamMerge? merge;
}

enum TeamSyncPhase { signedOut, teamRequired, syncing, synced, conflict, error }

class TeamSyncService extends ChangeNotifier {
  TeamSyncService(this._store, this._client);

  final TeamStore _store;
  final SupabaseClient _client;
  StreamSubscription<AuthState>? _authSubscription;
  Timer? _timer;
  RealtimeChannel? _channel;
  TeamSyncPhase phase = TeamSyncPhase.signedOut;
  String statusMessage = 'Sign in to sync this team between your devices.';
  DateTime? lastSyncedAt;
  int dataGeneration = 0;
  SyncConflict? conflict;
  bool _syncing = false;
  DateTime? _lastRemoteCheck;
  DateTime? _retryAfter;
  int _failures = 0;
  String? teamId;
  String? teamName;
  String? inviteCode;
  String? displayName;
  bool isTeamOwner = false;
  List<TeamMember> members = [];

  bool get isSignedIn => _client.auth.currentUser != null;
  String? get currentUserId => _client.auth.currentUser?.id;
  String? get signedInEmail => _client.auth.currentUser?.email;

  void start() {
    _authSubscription = _client.auth.onAuthStateChange.listen((state) {
      if (state.session == null) {
        teamId = null;
        teamName = null;
        inviteCode = null;
        displayName = null;
        isTeamOwner = false;
        members = [];
        if (_channel != null) _client.removeChannel(_channel!);
        _channel = null;
        conflict = null;
        _setPhase(
          TeamSyncPhase.signedOut,
          'Sign in to sync this team between your devices.',
        );
      } else {
        refreshTeam();
      }
    });
    if (isSignedIn) {
      refreshTeam();
    }
    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_syncing ||
          teamId == null ||
          (_retryAfter != null && DateTime.now().isBefore(_retryAfter!))) {
        return;
      }
      try {
        final state = await _store.localSyncState();
        final hasPendingChanges =
            state.lastSyncedRevision == null ||
            state.localRevision != state.lastSyncedRevision;
        final checkRemote =
            _lastRemoteCheck == null ||
            DateTime.now().difference(_lastRemoteCheck!) >=
                const Duration(minutes: 1);
        if (hasPendingChanges || checkRemote) {
          await syncNow(forceRemoteCheck: checkRemote);
        }
      } catch (_) {
        // A failed local status read is retried on the next timer tick.
      }
    });
  }

  Future<void> signIn(String email, String password) async {
    try {
      await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    } on AuthException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not sign in. Check your connection.',
      );
    }
  }

  Future<void> createAccount(String email, String password) async {
    try {
      final response = await _client.auth.signUp(
        email: email.trim(),
        password: password,
      );
      if (response.session == null) {
        _setPhase(
          TeamSyncPhase.signedOut,
          'Check your email to confirm the account, then sign in here.',
        );
      }
    } on AuthException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not create the account. Check your connection.',
      );
    }
  }

  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } on AuthException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not sign out. Please try again.');
    }
  }

  Future<void> onAppResumed() => refreshTeam();

  Future<void> refreshTeam() async {
    if (!isSignedIn) return;
    try {
      final id = await _client.rpc<String?>('my_team_id');
      if (id == null) {
        teamId = null;
        teamName = null;
        inviteCode = null;
        displayName = null;
        isTeamOwner = false;
        members = [];
        _setPhase(
          TeamSyncPhase.teamRequired,
          'Create a team or join one to sync.',
        );
        return;
      }
      final team = await _client
          .from('teams')
          .select('name,invite_code,owner_id')
          .eq('id', id)
          .single();
      final teamMembers = await _client
          .from('team_members')
          .select('user_id,display_name')
          .eq('team_id', id);
      teamId = id;
      teamName = team['name'] as String;
      inviteCode = team['invite_code'] as String;
      isTeamOwner = team['owner_id'] == _client.auth.currentUser?.id;
      displayName = (teamMembers as List)
          .cast<Map<String, dynamic>>()
          .where((member) => member['user_id'] == _client.auth.currentUser?.id)
          .map((member) => member['display_name'] as String)
          .firstOrNull;
      members = teamMembers
          .map(
            (member) => TeamMember(
              member['user_id'] as String,
              member['display_name'] as String,
            ),
          )
          .toList();
      _subscribe(id);
      await syncNow(forceRemoteCheck: true);
    } catch (_) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not load team settings. Try again.',
      );
    }
  }

  void _subscribe(String id) {
    if (_channel != null) _client.removeChannel(_channel!);
    _channel = _client
        .channel('team-snapshot-$id')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'shared_team_snapshots',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'team_id',
            value: id,
          ),
          callback: (_) => syncNow(forceRemoteCheck: true),
        )
        .subscribe();
  }

  Future<void> createTeam(String name, String personName) async {
    try {
      await _client.rpc<String>(
        'create_team',
        params: {'p_name': name.trim(), 'p_display_name': personName.trim()},
      );
      await refreshTeam();
    } on PostgrestException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not create the team. Try again.');
    }
  }

  Future<void> joinTeam(String code, String personName) async {
    try {
      await _client.rpc<String>(
        'join_team',
        params: {
          'p_invite_code': code.trim(),
          'p_display_name': personName.trim(),
        },
      );
      await refreshTeam();
    } on PostgrestException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not join the team. Try again.');
    }
  }

  Future<void> updateDetails({String? personName, String? name}) async {
    final id = teamId;
    final user = _client.auth.currentUser;
    if (id == null || user == null) return;
    try {
      if (personName != null && personName.trim().isNotEmpty) {
        await _client
            .from('team_members')
            .update({'display_name': personName.trim()})
            .eq('team_id', id)
            .eq('user_id', user.id);
      }
      if (name != null && name.trim().isNotEmpty) {
        await _client.from('teams').update({'name': name.trim()}).eq('id', id);
      }
      await refreshTeam();
    } on PostgrestException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not save team details. Try again.');
    }
  }

  Future<void> updateEmail(String email) async {
    try {
      await _client.auth.updateUser(UserAttributes(email: email.trim()));
      _setPhase(phase, 'Check your email to confirm the address change.');
    } on AuthException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not change email. Try again.');
    }
  }

  Future<void> updatePassword(String password) async {
    try {
      await _client.auth.updateUser(UserAttributes(password: password));
      _setPhase(phase, 'Password updated.');
    } on AuthException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not change password. Try again.');
    }
  }

  Future<void> rotateInvite() async {
    final id = teamId;
    if (id == null) return;
    try {
      inviteCode = await _client.rpc<String>(
        'rotate_team_invite',
        params: {'p_team_id': id},
      );
      notifyListeners();
    } on PostgrestException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not reset the invite code.');
    }
  }

  Future<void> removeMember(String userId) async {
    final id = teamId;
    if (id == null) return;
    try {
      await _client.rpc<void>(
        'remove_team_member',
        params: {'p_team_id': id, 'p_user_id': userId},
      );
      await refreshTeam();
    } on PostgrestException catch (error) {
      _setPhase(TeamSyncPhase.error, error.message);
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not remove the team member.');
    }
  }

  Future<void> syncNow({bool forceRemoteCheck = false}) async {
    if (_syncing || !isSignedIn || teamId == null) return;
    if (phase == TeamSyncPhase.conflict && !forceRemoteCheck) return;
    final currentTeamId = teamId!;
    _syncing = true;
    conflict = null;
    _setPhase(TeamSyncPhase.syncing, 'Checking for team updates…');
    try {
      await _store.prepareSyncForUser(currentTeamId);
      final local = await _store.localSyncState();
      lastSyncedAt = local.lastSyncedAt?.toLocal();
      final localBackup = await _store.exportBackup();
      final remote = await _readRemote();
      _lastRemoteCheck = DateTime.now();
      await _synchronize(local, localBackup, remote);
      _failures = 0;
      _retryAfter = null;
    } on LocalSyncConflictException {
      _setPhase(
        TeamSyncPhase.error,
        'Local data changed during sync. Sync again to retry safely.',
      );
    } on FormatException catch (error) {
      _setPhase(
        TeamSyncPhase.error,
        'Cloud backup is invalid: ${error.message}',
      );
    } on PostgrestException catch (error) {
      if (error.code == '40001') {
        _setPhase(
          TeamSyncPhase.error,
          'The cloud copy changed during sync. Sync again to review both copies.',
        );
      } else if (error.code == '42501') {
        teamId = null;
        _setPhase(
          TeamSyncPhase.teamRequired,
          'You no longer have access to this team.',
        );
      } else {
        _setPhase(TeamSyncPhase.error, 'Cloud sync failed: ${error.message}');
      }
    } catch (_) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not reach cloud sync. Your changes remain on this device.',
      );
    } finally {
      if (phase == TeamSyncPhase.error) {
        _failures++;
        final seconds = (1 << _failures.clamp(0, 6)) * 2;
        _retryAfter = DateTime.now().add(Duration(seconds: seconds));
      }
      _syncing = false;
    }
  }

  Future<void> _synchronize(
    LocalSyncState local,
    TeamBackup localBackup,
    RemoteTeamSnapshot? remote,
  ) async {
    final hasLocalData = await _store.hasTeamData();
    if (remote == null) {
      if (local.lastSyncedRevision != null && local.remoteRevision > 0) {
        final membership = await _client.rpc<String?>('my_team_id');
        if (membership != teamId) {
          teamId = null;
          conflict = null;
          _setPhase(
            TeamSyncPhase.teamRequired,
            'You no longer have access to this team.',
          );
          return;
        }
        conflict = SyncConflict(
          localRevision: local.localRevision,
          remoteSnapshot: null,
        );
        _setPhase(
          TeamSyncPhase.conflict,
          'The cloud copy is missing. Keep this device’s copy to upload it again.',
        );
        return;
      }
      if (!hasLocalData) {
        await _store.markSyncState(
          lastSyncedRevision: local.localRevision,
          remoteRevision: 0,
          baselinePayload: localBackup.toJsonString(),
        );
        _setPhase(TeamSyncPhase.synced, 'This team is ready to sync.');
        lastSyncedAt = DateTime.now();
        return;
      }
      await _upload(local, localBackup, expectedRemoteRevision: 0);
      return;
    }

    if (local.lastSyncedRevision == null) {
      if (!hasLocalData) {
        await _restore(remote, local.localRevision);
      } else {
        _offerConflict(local.localRevision, remote);
      }
      return;
    }

    if (remote.revision < local.remoteRevision) {
      _offerConflict(local.localRevision, remote);
      return;
    }

    final localIsClean = local.localRevision == local.lastSyncedRevision;
    if (localIsClean) {
      if (remote.revision == local.remoteRevision) {
        _setPhase(TeamSyncPhase.synced, 'All changes are synced.');
        return;
      }
      await _restore(remote, local.localRevision);
      return;
    }

    if (remote.revision == local.remoteRevision) {
      await _upload(
        local,
        localBackup,
        expectedRemoteRevision: remote.revision,
      );
      return;
    }

    if (local.baselinePayload != null) {
      final merge = TeamMerge.compare(
        TeamBackup.fromJsonString(local.baselinePayload!),
        localBackup,
        remote.backup,
      );
      if (merge.conflicts.isEmpty) {
        try {
          await _stageAndUpload(merge.resolve({}), local.localRevision, remote);
        } on FormatException {
          _offerConflict(local.localRevision, remote);
        }
        return;
      }
      conflict = SyncConflict(
        localRevision: local.localRevision,
        remoteSnapshot: remote,
        merge: merge,
      );
      _setPhase(
        TeamSyncPhase.conflict,
        '${merge.conflicts.length} item(s) changed on both devices. Review them in Settings.',
      );
      return;
    }
    _offerConflict(local.localRevision, remote);
  }

  Future<void> _stageAndUpload(
    TeamBackup backup,
    int localRevision,
    RemoteTeamSnapshot remote,
  ) async {
    final staged = await _store.stageMergedSnapshot(
      backup: backup,
      expectedLocalRevision: localRevision,
      remoteRevision: remote.revision,
      remotePayload: remote.payload,
    );
    dataGeneration++;
    notifyListeners();
    await _upload(staged, backup, expectedRemoteRevision: remote.revision);
  }

  Future<void> resolveMerge(Set<String> useCloud) async {
    final pending = conflict;
    final remote = pending?.remoteSnapshot;
    final merge = pending?.merge;
    if (pending == null || remote == null || merge == null || _syncing) return;
    _syncing = true;
    _setPhase(TeamSyncPhase.syncing, 'Saving reviewed changes…');
    try {
      final current = await _readRemote();
      if (current?.revision != remote.revision) {
        _syncing = false;
        await syncNow(forceRemoteCheck: true);
        return;
      }
      await _stageAndUpload(
        merge.resolve(useCloud),
        pending.localRevision,
        remote,
      );
      conflict = null;
    } on LocalSyncConflictException {
      _setPhase(
        TeamSyncPhase.error,
        'Local data changed. Sync again to review.',
      );
    } on FormatException {
      _setPhase(
        TeamSyncPhase.conflict,
        'The selected items leave an invalid team. Review related changes together.',
      );
    } catch (_) {
      _setPhase(TeamSyncPhase.error, 'Could not save the reviewed changes.');
    } finally {
      _syncing = false;
    }
  }

  void _offerConflict(int localRevision, RemoteTeamSnapshot remote) {
    conflict = SyncConflict(
      localRevision: localRevision,
      remoteSnapshot: remote,
    );
    _setPhase(
      TeamSyncPhase.conflict,
      'Both this device and the cloud have changes. Choose which copy to keep.',
    );
  }

  Future<void> _restore(
    RemoteTeamSnapshot remote,
    int expectedLocalRevision,
  ) async {
    await _store.restoreCloudSnapshot(
      backup: remote.backup,
      expectedLocalRevision: expectedLocalRevision,
      remoteRevision: remote.revision,
      baselinePayload: remote.payload,
    );
    lastSyncedAt = DateTime.now();
    dataGeneration++;
    _setPhase(TeamSyncPhase.synced, 'Downloaded the latest cloud copy.');
  }

  Future<void> _upload(
    LocalSyncState local,
    TeamBackup backup, {
    required int expectedRemoteRevision,
  }) async {
    final payload = backup.toJsonString();
    final id = teamId;
    if (id == null) throw const AuthException('Join a team to sync.');
    final result = await _client.rpc<int>(
      'sync_shared_team_snapshot',
      params: {
        'p_team_id': id,
        'p_expected_revision': expectedRemoteRevision,
        'p_payload': jsonDecode(payload),
      },
    );
    await _store.markSyncState(
      lastSyncedRevision: local.localRevision,
      remoteRevision: result,
      baselinePayload: payload,
    );
    lastSyncedAt = DateTime.now();
    _setPhase(TeamSyncPhase.synced, 'Uploaded the latest team changes.');
  }

  Future<RemoteTeamSnapshot?> _readRemote() async {
    final id = teamId;
    if (id == null) return null;
    final row = await _client
        .from('shared_team_snapshots')
        .select('revision,payload')
        .eq('team_id', id)
        .maybeSingle();
    if (row == null) return null;
    return RemoteTeamSnapshot(
      revision: row['revision'] as int,
      payload: row['payload'] as String,
    );
  }

  Future<void> keepThisDevice() async {
    final pending = conflict;
    if (pending == null || _syncing) return;
    _syncing = true;
    conflict = null;
    _setPhase(TeamSyncPhase.syncing, 'Checking the copies before upload…');
    try {
      final local = await _store.localSyncState();
      if (local.localRevision != pending.localRevision) {
        _setPhase(
          TeamSyncPhase.error,
          'This device changed while resolving the conflict. Sync again first.',
        );
        return;
      }
      final remote = await _readRemote();
      final expected = pending.remoteSnapshot?.revision ?? 0;
      if (remote?.revision != (expected == 0 ? null : expected)) {
        if (remote == null) {
          conflict = SyncConflict(
            localRevision: local.localRevision,
            remoteSnapshot: null,
          );
          _setPhase(
            TeamSyncPhase.conflict,
            'The cloud copy changed again. Review the current copies before choosing.',
          );
        } else {
          _offerConflict(local.localRevision, remote);
        }
        return;
      }
      await _upload(
        local,
        await _store.exportBackup(),
        expectedRemoteRevision: expected,
      );
    } on PostgrestException catch (error) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not keep this copy: ${error.message}',
      );
    } catch (_) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not keep this device’s copy. Try again.',
      );
    } finally {
      _syncing = false;
    }
  }

  Future<void> useCloudCopy() async {
    final pending = conflict;
    final remote = pending?.remoteSnapshot;
    if (pending == null || remote == null || _syncing) return;
    _syncing = true;
    try {
      final currentRemote = await _readRemote();
      if (currentRemote?.revision != remote.revision) {
        final localState = await _store.localSyncState();
        if (currentRemote == null) {
          conflict = SyncConflict(
            localRevision: localState.localRevision,
            remoteSnapshot: null,
          );
          _setPhase(
            TeamSyncPhase.conflict,
            'The cloud copy changed again. Review the current copies before choosing.',
          );
        } else {
          _offerConflict(localState.localRevision, currentRemote);
        }
        return;
      }
      await _store.restoreCloudSnapshot(
        backup: remote.backup,
        expectedLocalRevision: pending.localRevision,
        remoteRevision: remote.revision,
        baselinePayload: remote.payload,
      );
      conflict = null;
      lastSyncedAt = DateTime.now();
      dataGeneration++;
      _setPhase(TeamSyncPhase.synced, 'Restored the cloud copy.');
    } on LocalSyncConflictException {
      conflict = null;
      _setPhase(
        TeamSyncPhase.error,
        'Local data changed while resolving the conflict. Sync again first.',
      );
    } catch (_) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not restore the cloud copy. Your local data remains available.',
      );
    } finally {
      _syncing = false;
    }
  }

  void _setPhase(TeamSyncPhase next, String message) {
    phase = next;
    statusMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _authSubscription?.cancel();
    if (_channel != null) _client.removeChannel(_channel!);
    super.dispose();
  }
}
