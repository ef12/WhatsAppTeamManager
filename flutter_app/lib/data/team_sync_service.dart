import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'team_backup.dart';
import 'team_store.dart';

class RemoteTeamSnapshot {
  const RemoteTeamSnapshot({required this.revision, required this.payload});

  final int revision;
  final String payload;

  TeamBackup get backup => TeamBackup.fromJsonString(payload);
}

class SyncConflict {
  const SyncConflict({
    required this.localRevision,
    required this.remoteSnapshot,
  });

  final int localRevision;
  final RemoteTeamSnapshot? remoteSnapshot;
}

enum TeamSyncPhase { signedOut, syncing, synced, conflict, error }

class TeamSyncService extends ChangeNotifier {
  TeamSyncService(this._store, this._client);

  final TeamStore _store;
  final SupabaseClient _client;
  StreamSubscription<AuthState>? _authSubscription;
  Timer? _timer;
  TeamSyncPhase phase = TeamSyncPhase.signedOut;
  String statusMessage = 'Sign in to sync this team between your devices.';
  DateTime? lastSyncedAt;
  int dataGeneration = 0;
  SyncConflict? conflict;
  bool _syncing = false;
  DateTime? _lastRemoteCheck;

  bool get isSignedIn => _client.auth.currentUser != null;
  String? get signedInEmail => _client.auth.currentUser?.email;

  void start() {
    _authSubscription = _client.auth.onAuthStateChange.listen((state) {
      if (state.session == null) {
        conflict = null;
        _setPhase(
          TeamSyncPhase.signedOut,
          'Sign in to sync this team between your devices.',
        );
      } else {
        syncNow(forceRemoteCheck: true);
      }
    });
    if (isSignedIn) {
      syncNow(forceRemoteCheck: true);
    }
    _timer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_syncing || !isSignedIn) return;
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
          syncNow(forceRemoteCheck: checkRemote);
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

  Future<void> onAppResumed() => syncNow(forceRemoteCheck: true);

  Future<void> syncNow({bool forceRemoteCheck = false}) async {
    if (_syncing || !isSignedIn) return;
    if (phase == TeamSyncPhase.conflict && !forceRemoteCheck) return;
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    _syncing = true;
    conflict = null;
    _setPhase(TeamSyncPhase.syncing, 'Checking for team updates…');
    try {
      await _store.prepareSyncForUser(userId);
      final local = await _store.localSyncState();
      lastSyncedAt = local.lastSyncedAt?.toLocal();
      final localBackup = await _store.exportBackup();
      final remote = await _readRemote();
      _lastRemoteCheck = DateTime.now();
      await _synchronize(local, localBackup, remote);
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
      } else {
        _setPhase(TeamSyncPhase.error, 'Cloud sync failed: ${error.message}');
      }
    } catch (_) {
      _setPhase(
        TeamSyncPhase.error,
        'Could not reach cloud sync. Your changes remain on this device.',
      );
    } finally {
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

    _offerConflict(local.localRevision, remote);
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
    final user = _client.auth.currentUser;
    if (user == null) throw const AuthException('Sign in to sync this team.');
    final result = await _client.rpc<int>(
      'sync_team_snapshot',
      params: {
        'p_expected_revision': expectedRemoteRevision,
        'p_payload': jsonDecode(payload),
      },
    );
    await _store.markSyncState(
      lastSyncedRevision: local.localRevision,
      remoteRevision: result,
    );
    lastSyncedAt = DateTime.now();
    _setPhase(TeamSyncPhase.synced, 'Uploaded the latest team changes.');
  }

  Future<RemoteTeamSnapshot?> _readRemote() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    final row = await _client
        .from('team_snapshots')
        .select('revision,payload')
        .eq('user_id', user.id)
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
    super.dispose();
  }
}
