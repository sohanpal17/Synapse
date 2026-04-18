import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';
import '../models/case_model.dart';
import '../models/reminder_models.dart';
import '../models/notice_models.dart';
import '../models/messaging_models.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/hive_service.dart';
import '../services/sync_service.dart';
import '../services/connectivity_service.dart';

// ══════════ SERVICES ══════════
final authServiceProvider = Provider((_) => AuthService());
final firestoreServiceProvider = Provider((_) => FirestoreService());
final syncServiceProvider = Provider((_) => SyncService());

String _normalizeWorkStatus(dynamic raw) {
  final status = (raw ?? '').toString().trim().toLowerCase();
  if (status == 'completed' ||
      status == 'complete' ||
      status == 'done' ||
      status == 'closed') {
    return 'completed';
  }
  return 'inProgress';
}

// ══════════ AUTH STATE ══════════
final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

// ══════════ CURRENT USER ══════════
final currentUserProvider =
    StateNotifierProvider<CurrentUserNotifier, UserModel?>((ref) {
  return CurrentUserNotifier(ref.read(authServiceProvider));
});

class CurrentUserNotifier extends StateNotifier<UserModel?> {
  final AuthService _authService;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;

  CurrentUserNotifier(this._authService) : super(null) {
    _loadCachedUser();
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_handleAuthChanged);
  }

  void _loadCachedUser() {
    final cached = _authService.getCachedUser();
    final authUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (cached != null && authUid.isNotEmpty && cached.uid == authUid) {
      state = cached;
      return;
    }
    state = null;
  }

  Future<void> _handleAuthChanged(User? fbUser) async {
    await _profileSub?.cancel();
    _profileSub = null;

    if (fbUser == null) {
      state = null;
      return;
    }

    final cached = _authService.getCachedUser();
    if (cached != null && cached.uid == fbUser.uid) {
      state = cached;
    }

    // Keep profile in sync so pending/approved transitions are reflected live.
    _profileSub = FirebaseFirestore.instance
        .collection('users')
        .doc(fbUser.uid)
        .snapshots()
        .listen((doc) async {
      if (!doc.exists) return;
      final map = doc.data();
      if (map == null) return;
      final normalized = Map<String, dynamic>.from(map);
      normalized.putIfAbsent('uid', () => doc.id);
      final remote = UserModel.fromMap(normalized);
      await HiveService.put(HiveService.userBox, 'current_user', remote.toMap());
      state = remote;
    }, onError: (e) {
      debugPrint('Failed profile stream for ${fbUser.uid}: $e');
    });

    try {
      final remote = await _authService.getUserById(fbUser.uid);
      if (remote != null) {
        await HiveService.put(HiveService.userBox, 'current_user', remote.toMap());
        state = remote;
        return;
      }
    } catch (e) {
      debugPrint('Failed to fetch profile for auth user ${fbUser.uid}: $e');
    }

    // Do not force sign-out here. Registration writes may still be in progress.
    // Keep current state (cached or null) and let profile stream resolve.
  }

  void setUser(UserModel user) => state = user;
  void clear() => state = null;

  @override
  void dispose() {
    _profileSub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }
}

// ══════════ CONNECTIVITY ══════════
final connectivityProvider = StreamProvider<bool>((ref) {
  return ConnectivityService.onConnectivityChanged;
});

// ══════════ CASES ══════════
final casesProvider =
    StateNotifierProvider<CasesNotifier, List<CaseModel>>((ref) {
  return CasesNotifier();
});

class CasesNotifier extends StateNotifier<List<CaseModel>> {
  StreamSubscription? _sub;
  StreamSubscription<User?>? _authSub;

  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  bool _isCaseVisibleToCurrentUser(Map<String, dynamic> map, String uid) {
    if (uid.isEmpty) return false;

    final ownerUid = (map['ownerUid'] as String? ?? '').trim();
    if (ownerUid == uid) return true;

    final participants = List<String>.from(map['participantIds'] ?? const []);
    if (participants.contains(uid)) return true;

    final assignedLawyers = List<String>.from(map['assignedLawyerIds'] ?? const []);
    if (assignedLawyers.contains(uid)) return true;

    final assignedInterns = List<String>.from(map['assignedInternIds'] ?? const []);
    if (assignedInterns.contains(uid)) return true;

    final assignedMembers = List<String>.from(map['assignedMemberIds'] ?? const []);
    if (assignedMembers.contains(uid)) return true;
    return false;
  }

  List<String> _computeCaseParticipants(Map<String, dynamic> map) {
    final participants = <String>{
      ...List<String>.from(map['participantIds'] ?? const []),
      ...List<String>.from(map['assignedLawyerIds'] ?? const []),
      ...List<String>.from(map['assignedInternIds'] ?? const []),
      ...List<String>.from(map['assignedMemberIds'] ?? const []),
    };

    final ownerUid = (map['ownerUid'] as String? ?? '').trim();
    if (ownerUid.isNotEmpty) {
      participants.add(ownerUid);
    }

    participants.removeWhere((id) => id.trim().isEmpty);
    return participants.toList();
  }

  CasesNotifier() : super([]) {
    _loadFromHive();
    _listenToFirestore();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      _sub?.cancel();
      _loadFromHive();
      _listenToFirestore();
    });
  }

  void _loadFromHive() {
    final uid = _currentUid;
    if (uid.isEmpty) {
      state = const [];
      return;
    }
    final cached = HiveService.getAll(HiveService.casesBox);
    final Map<String, CaseModel> uniqueByCino = {};
    for (final m in cached) {
      try {
        if (!_isCaseVisibleToCurrentUser(m, uid)) {
          continue;
        }
        final parsed = CaseModel.fromMap(m);
        if (parsed.cino.trim().isEmpty) continue;
        uniqueByCino[parsed.cino] = parsed;
      } catch (e) {
        debugPrint('Failed to parse case from local cache: $e');
      }
    }

    final parsed = uniqueByCino.values.toList();

    parsed.sort((a, b) {
      if (a.nextHearingDate == null && b.nextHearingDate == null) return 0;
      if (a.nextHearingDate == null) return 1;
      if (b.nextHearingDate == null) return -1;
      return b.nextHearingDate!.compareTo(a.nextHearingDate!); // newest first
    });

    state = parsed;
  }

  void _listenToFirestore() {
    _sub = FirestoreService().watchCasesRaw().listen((cases) async {
      // Merge Firestore results INTO Hive (don't discard local-only data)
      final writes = <Future<void>>[];
      for (final c in cases) {
        final cino = (c['cino'] as String? ?? '').trim();
        if (cino.isEmpty) continue;
        writes.add(HiveService.put(HiveService.casesBox, cino, c));
      }
      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }
      // Rebuild state from Hive (contains both synced + unsynced local data)
      _loadFromHive();
    }, onError: (_) {
      // Stay on cached data
    });
  }

  void refresh() => _loadFromHive();

  Future<void> updateCase(
    String cino,
    Map<String, dynamic> updates, {
    bool queueSync = true,
  }) async {
    final existing = HiveService.get(HiveService.casesBox, cino);
    if (existing != null) {
      existing['ownerUid'] = _currentUid;
      existing.addAll(updates);
      existing['participantIds'] = _computeCaseParticipants(existing);
      existing['updatedAt'] = DateTime.now().toIso8601String();
      await HiveService.put(HiveService.casesBox, cino, existing);
      if (queueSync) {
        await SyncService.queueAction(
          action: 'UPDATE',
          collection: 'cases',
          documentId: cino,
          data: existing,
        );
      }
      _loadFromHive();
    }
  }

  Future<void> addCase(CaseModel c) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    final map = c.toMap();
    map['ownerUid'] = uid;
    map['source'] = 'manual';
    map['participantIds'] = _computeCaseParticipants(map);
    await HiveService.put(HiveService.casesBox, c.cino, map);
    await SyncService.queueAction(
      action: 'CREATE',
      collection: 'cases',
      documentId: c.cino,
      data: map,
    );
    _loadFromHive();
  }

  Future<void> deleteCase(String cino) async {
    await HiveService.delete(HiveService.casesBox, cino);
    await SyncService.queueAction(
      action: 'DELETE',
      collection: 'cases',
      documentId: cino,
      data: {},
    );
    _loadFromHive();
  }

  List<CaseModel> get activeCases => state.where((c) => !c.isClosed).toList();
  List<CaseModel> get closedCases => state.where((c) => c.isClosed).toList();

  @override
  void dispose() {
    _sub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }
}

// ══════════ TASKS (from Hive, synced) ══════════
final tasksProvider =
    StateNotifierProvider<TasksNotifier, List<Map<String, dynamic>>>((ref) {
  return TasksNotifier();
});

class TasksNotifier extends StateNotifier<List<Map<String, dynamic>>> {
  StreamSubscription? _sub;
  StreamSubscription<User?>? _authSub;

  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  TasksNotifier() : super([]) {
    _load();
    _listenToFirestore();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      _sub?.cancel();
      _load();
      _listenToFirestore();
    });
  }

  void _load() {
    final uid = _currentUid;
    final all = HiveService.getAll(HiveService.tasksBox);
    if (uid.isEmpty) {
      state = const [];
      return;
    }
    state = all.where((t) {
      final participants = List<String>.from(t['participantIds'] ?? const []);
      final assigned = List<String>.from(t['assignedJuniorIds'] ?? const []);
      final assignedMany = List<String>.from(t['assignedToIds'] ?? const []);
      final assignedSingle = (t['assignedToId'] ?? '').toString();
      final isOwner = t['createdBy'] == uid;
      final isPublic = t['isPublic'] == true || t['visibility'] == 'everyone';
      final isAssigned = assigned.contains(uid) ||
          assignedMany.contains(uid) ||
          assignedSingle == uid;

      // Keep legacy-safe visibility checks so assigned interns still see tasks
      // even when participantIds are stale or missing.
      if (participants.isNotEmpty) {
        return participants.contains(uid) || isOwner || isPublic || isAssigned;
      }

      return isOwner || isPublic || isAssigned;
    }).toList();
  }

  void _listenToFirestore() {
    _sub = FirestoreService().watchTasks().listen((data) async {
      final uid = _currentUid;
      final writes = <Future<void>>[];
      final incomingIds = <String>{};
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          incomingIds.add(id);
          final normalized = Map<String, dynamic>.from(m)
            ..['status'] = _normalizeWorkStatus(m['status']);

          // Keep the newest per-user clear marker to avoid completed rows
          // briefly reappearing when an older snapshot arrives.
          if (uid.isNotEmpty) {
            final local = HiveService.get(HiveService.tasksBox, id);
            final localMap = Map<String, dynamic>.from(
              local?['clearedCompletedAtByUser'] ?? {},
            );
            final incomingMap = Map<String, dynamic>.from(
              normalized['clearedCompletedAtByUser'] ?? {},
            );
            final localAt = DateTime.tryParse((localMap[uid] ?? '').toString());
            final incomingAt =
                DateTime.tryParse((incomingMap[uid] ?? '').toString());
            if (localAt != null &&
                (incomingAt == null || localAt.isAfter(incomingAt))) {
              incomingMap[uid] = localAt.toIso8601String();
              normalized['clearedCompletedAtByUser'] = incomingMap;
            }
          }

          writes.add(HiveService.put(HiveService.tasksBox, id, normalized));
        }
      }

      // Remove stale task rows (for example after creator deletes a task)
      // while preserving pending local creates that are not yet on server.
      final queue = HiveService.getSyncQueue();
      final pendingCreateIds = queue
          .where((q) =>
              (q['collection'] ?? '') == 'tasks' &&
              (q['action'] ?? '') == 'CREATE')
          .map((q) => (q['documentId'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      final visibleIds = state
          .map((t) => (t['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      for (final staleId in visibleIds.difference(incomingIds)) {
        if (pendingCreateIds.contains(staleId)) continue;
        writes.add(HiveService.delete(HiveService.tasksBox, staleId));
      }

      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }
      _load();
    }, onError: (_) {});
  }

  Future<void> addTask(Map<String, dynamic> task) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    final participants = <String>{
      uid,
      ...List<String>.from(task['assignedJuniorIds'] ?? const []),
      ...List<String>.from(task['assignedToIds'] ?? const []),
      (task['assignedToId'] ?? '').toString(),
    }..removeWhere((e) => e.trim().isEmpty);
    final local = Map<String, dynamic>.from(task)
      ..['participantIds'] = participants.toList()
      ..['status'] = _normalizeWorkStatus(task['status']);

    await HiveService.put(HiveService.tasksBox, task['id'], local);
    await SyncService.queueAction(
      action: 'CREATE',
      collection: 'tasks',
      documentId: task['id'],
      data: local,
    );
    _load();
  }

  Future<void> updateTask(String id, Map<String, dynamic> updates) async {
    final existing = HiveService.get(HiveService.tasksBox, id);
    if (existing != null) {
      final normalizedUpdates = Map<String, dynamic>.from(updates);
      if (normalizedUpdates.containsKey('status')) {
        normalizedUpdates['status'] =
            _normalizeWorkStatus(normalizedUpdates['status']);
      }

      existing.addAll(normalizedUpdates);
      existing['updatedAt'] = DateTime.now().toIso8601String();
      final updatePayload = <String, dynamic>{
        ...normalizedUpdates,
        'updatedAt': existing['updatedAt'],
      };
      await HiveService.put(HiveService.tasksBox, id, existing);

      final isStatusOnly = normalizedUpdates.containsKey('status') &&
          normalizedUpdates.keys.every((k) => k == 'status' || k == 'updatedAt');

      if (isStatusOnly) {
        try {
          await FirestoreService().updateTaskStatus(
            id,
            (normalizedUpdates['status'] ?? 'pending').toString(),
          );
        } catch (e) {
          await SyncService.queueAction(
            action: 'UPDATE',
            collection: 'tasks',
            documentId: id,
            data: updatePayload,
          );
          debugPrint('Task status callable failed; queued sync fallback: $e');
        }
      } else {
        try {
          await FirestoreService().updateTaskDetails(id, updatePayload);
        } catch (e) {
          final text = e.toString().toLowerCase();
          final isRetryable = text.contains('unavailable') ||
              text.contains('deadline-exceeded') ||
              text.contains('network') ||
              text.contains('timeout') ||
              text.contains('internal');
          if (!isRetryable) rethrow;

          await SyncService.queueAction(
            action: 'UPDATE',
            collection: 'tasks',
            documentId: id,
            data: updatePayload,
          );
          debugPrint('Task detail callable failed; queued sync fallback: $e');
        }
      }
      _load();
    }
  }

  /// Update fields that assignees are permitted to write (viewedBy, isEscalated, autoEscalate).
  Future<void> updateTaskAssignableFields(
      String id, Map<String, dynamic> updates) async {
    final existing = HiveService.get(HiveService.tasksBox, id);
    if (existing != null) {
      existing.addAll(updates);
      await HiveService.put(HiveService.tasksBox, id, existing);
      try {
        await FirestoreService().updateTaskAssignableFields(id, updates);
      } catch (e) {
        // Fallback to sync queue if offline or failed
        await SyncService.queueAction(
          action: 'UPDATE',
          collection: 'tasks',
          documentId: id,
          data: updates,
        );
      }
      _load();
    }
  }

  Future<void> clearCompletedTasksForCurrentUser(List<String> taskIds) async {
    final uid = _currentUid;
    if (uid.isEmpty || taskIds.isEmpty) return;

    final now = DateTime.now().toIso8601String();
    for (final id in taskIds) {
      final existing = HiveService.get(HiveService.tasksBox, id);
      if (existing == null) continue;
      final map =
          Map<String, dynamic>.from(existing['clearedCompletedAtByUser'] ?? {});
      map[uid] = now;
      existing['clearedCompletedAtByUser'] = map;
      existing['updatedAt'] = now;
      await HiveService.put(HiveService.tasksBox, id, existing);
    }

    _load();
    await FirestoreService().clearCompletedTasksForUser(taskIds);
  }

  Future<void> addTaskComment({
    required String taskId,
    required String text,
    required String authorUid,
    required String authorName,
  }) async {
    final existing = HiveService.get(HiveService.tasksBox, taskId);
    if (existing == null) return;

    final now = DateTime.now().toIso8601String();
    final comment = <String, dynamic>{
      'id': '${DateTime.now().millisecondsSinceEpoch}_$authorUid',
      'text': text,
      'authorUid': authorUid,
      'authorName': authorName,
      'createdAt': now,
    };

    final comments = List<Map<String, dynamic>>.from(
      (existing['comments'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map? ?? {})),
    )..add(comment);

    existing['comments'] = comments;
    existing['updatedAt'] = now;
    await HiveService.put(HiveService.tasksBox, taskId, existing);
    _load();

    await FirestoreService().addTaskComment(
      taskId: taskId,
      text: text,
      authorName: authorName,
    );
  }

  Future<void> deleteTask(String id) async {
    final uid = _currentUid;
    final existing = HiveService.get(HiveService.tasksBox, id);
    if (existing == null) return;
    final isCreator = (existing['createdBy'] ?? '').toString() == uid;
    if (!isCreator) return;

    await HiveService.delete(HiveService.tasksBox, id);
    _load();

    try {
      await FirestoreService().deleteTaskSecure(id);
    } catch (e) {
      await SyncService.queueAction(
        action: 'DELETE',
        collection: 'tasks',
        documentId: id,
        data: {},
      );
      debugPrint('Task delete callable failed; queued delete fallback: $e');
    }
  }

  void refresh() => _load();

  @override
  void dispose() {
    _sub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }
}

// ══════════ ASSIGNMENTS (Hive + Firestore) ══════════
final assignmentsProvider =
    StateNotifierProvider<AssignmentsNotifier, List<Map<String, dynamic>>>(
        (ref) {
  return AssignmentsNotifier();
});

class AssignmentsNotifier extends StateNotifier<List<Map<String, dynamic>>> {
  StreamSubscription? _sub;
  StreamSubscription<User?>? _authSub;

  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  List<String> _assignmentAssigneeIds(Map<String, dynamic> assignment) {
    final many = List<String>.from(assignment['assignedToIds'] ?? const []);
    if (many.isNotEmpty) return many;

    final single = (assignment['assignedToId'] as String? ?? '').trim();
    if (single.isEmpty) return const [];
    return [single];
  }

  AssignmentsNotifier() : super([]) {
    _loadFromHive();
    _listenToFirestore();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      _sub?.cancel();
      _loadFromHive();
      _listenToFirestore();
    });
  }

  void _loadFromHive() {
    final uid = _currentUid;
    final all = HiveService.getAll(HiveService.assignmentsBox);
    if (uid.isEmpty) {
      state = const [];
      return;
    }

    final filtered = all.where((a) {
      final participants = List<String>.from(a['participantIds'] ?? const []);
      final assignees = _assignmentAssigneeIds(a);
      final isOwner = a['createdBy'] == uid;
      final isAssignee = assignees.contains(uid);
      final isParticipant = participants.contains(uid);
      return isOwner || isAssignee || isParticipant;
    }).toList()
      ..sort((a, b) => (b['createdAt'] ?? '')
          .toString()
          .compareTo((a['createdAt'] ?? '').toString()));

    state = filtered;
  }

  void _listenToFirestore() {
    _sub = FirestoreService().watchAssignments().listen((data) async {
      final uid = _currentUid;
      final writes = <Future<void>>[];
      final incomingIds = <String>{};
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          incomingIds.add(id);
          final normalized = Map<String, dynamic>.from(m)
            ..['status'] = _normalizeWorkStatus(m['status']);

          // Keep the newest per-user clear marker to avoid completed rows
          // briefly reappearing when an older snapshot arrives.
          if (uid.isNotEmpty) {
            final local = HiveService.get(HiveService.assignmentsBox, id);
            final localMap = Map<String, dynamic>.from(
              local?['clearedCompletedAtByUser'] ?? {},
            );
            final incomingMap = Map<String, dynamic>.from(
              normalized['clearedCompletedAtByUser'] ?? {},
            );
            final localAt = DateTime.tryParse((localMap[uid] ?? '').toString());
            final incomingAt =
                DateTime.tryParse((incomingMap[uid] ?? '').toString());
            if (localAt != null &&
                (incomingAt == null || localAt.isAfter(incomingAt))) {
              incomingMap[uid] = localAt.toIso8601String();
              normalized['clearedCompletedAtByUser'] = incomingMap;
            }
          }

          writes.add(
            HiveService.put(HiveService.assignmentsBox, id, normalized),
          );
        }
      }

      final queue = HiveService.getSyncQueue();
      final pendingCreateIds = queue
          .where((q) =>
              (q['collection'] ?? '') == 'assignments' &&
              (q['action'] ?? '') == 'CREATE')
          .map((q) => (q['documentId'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      final visibleIds = state
          .map((a) => (a['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      for (final staleId in visibleIds.difference(incomingIds)) {
        if (pendingCreateIds.contains(staleId)) continue;
        writes.add(HiveService.delete(HiveService.assignmentsBox, staleId));
      }

      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }
      _loadFromHive();
    }, onError: (_) {});
  }

  Future<void> addAssignment(Map<String, dynamic> assignment) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    final id = assignment['id'] as String? ?? '';
    if (id.isEmpty) return;

    final assignees = _assignmentAssigneeIds(assignment);
    final participants = <String>{
      uid,
      ...assignees,
      ...List<String>.from(assignment['participantIds'] ?? const []),
    }..removeWhere((e) => e.isEmpty);

    final local = Map<String, dynamic>.from(assignment)
      ..['participantIds'] = participants.toList()
      ..['status'] = _normalizeWorkStatus(assignment['status']);

    await HiveService.put(HiveService.assignmentsBox, id, local);
    await SyncService.queueAction(
      action: 'CREATE',
      collection: 'assignments',
      documentId: id,
      data: local,
    );
    _loadFromHive();
  }

  Future<void> updateAssignment(String id, Map<String, dynamic> updates) async {
    final existing = HiveService.get(HiveService.assignmentsBox, id);
    if (existing == null) return;

    final normalizedUpdates = Map<String, dynamic>.from(updates);
    if (normalizedUpdates.containsKey('status')) {
      normalizedUpdates['status'] =
          _normalizeWorkStatus(normalizedUpdates['status']);
    }

    existing.addAll(normalizedUpdates);
    existing['updatedAt'] = DateTime.now().toIso8601String();
    final updatePayload = <String, dynamic>{
      ...normalizedUpdates,
      'updatedAt': existing['updatedAt'],
    };
    await HiveService.put(HiveService.assignmentsBox, id, existing);

    final isStatusOnly = normalizedUpdates.containsKey('status') &&
        normalizedUpdates.keys.every((k) => k == 'status' || k == 'updatedAt');

    if (isStatusOnly) {
      try {
        await FirestoreService().updateAssignmentStatus(
          id,
          (normalizedUpdates['status'] ?? 'pending').toString(),
        );
      } catch (e) {
        await SyncService.queueAction(
          action: 'UPDATE',
          collection: 'assignments',
          documentId: id,
          data: updatePayload,
        );
        debugPrint('Assignment status callable failed; queued sync fallback: $e');
      }
    } else {
      try {
        await FirestoreService().updateAssignmentDetails(id, updatePayload);
      } catch (e) {
        final text = e.toString().toLowerCase();
        final isRetryable = text.contains('unavailable') ||
            text.contains('deadline-exceeded') ||
            text.contains('network') ||
            text.contains('timeout') ||
            text.contains('internal');
        if (!isRetryable) rethrow;

        await SyncService.queueAction(
          action: 'UPDATE',
          collection: 'assignments',
          documentId: id,
          data: updatePayload,
        );
        debugPrint(
            'Assignment detail callable failed; queued sync fallback: $e');
      }
    }
    _loadFromHive();
  }

  /// Update fields that assignees are permitted to write in assignments.
  Future<void> updateAssignmentAssignableFields(
      String id, Map<String, dynamic> updates) async {
    final existing = HiveService.get(HiveService.assignmentsBox, id);
    if (existing != null) {
      existing.addAll(updates);
      await HiveService.put(HiveService.assignmentsBox, id, existing);
      try {
        await FirestoreService().updateAssignmentAssignableFields(id, updates);
      } catch (e) {
        await SyncService.queueAction(
          action: 'UPDATE',
          collection: 'assignments',
          documentId: id,
          data: updates,
        );
      }
      _loadFromHive();
    }
  }

  Future<void> clearCompletedAssignmentsForCurrentUser(
      List<String> assignmentIds) async {
    final uid = _currentUid;
    if (uid.isEmpty || assignmentIds.isEmpty) return;

    final now = DateTime.now().toIso8601String();
    for (final id in assignmentIds) {
      final existing = HiveService.get(HiveService.assignmentsBox, id);
      if (existing == null) continue;
      final map =
          Map<String, dynamic>.from(existing['clearedCompletedAtByUser'] ?? {});
      map[uid] = now;
      existing['clearedCompletedAtByUser'] = map;
      existing['updatedAt'] = now;
      await HiveService.put(HiveService.assignmentsBox, id, existing);
    }

    _loadFromHive();
    await FirestoreService().clearCompletedAssignmentsForUser(assignmentIds);
  }

  Future<void> addAssignmentComment({
    required String assignmentId,
    required String text,
    required String authorUid,
    required String authorName,
  }) async {
    final existing = HiveService.get(HiveService.assignmentsBox, assignmentId);
    if (existing == null) return;

    final now = DateTime.now().toIso8601String();
    final comment = <String, dynamic>{
      'id': '${DateTime.now().millisecondsSinceEpoch}_$authorUid',
      'text': text,
      'authorUid': authorUid,
      'authorName': authorName,
      'createdAt': now,
    };

    final comments = List<Map<String, dynamic>>.from(
      (existing['comments'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map? ?? {})),
    )..add(comment);

    existing['comments'] = comments;
    existing['updatedAt'] = now;
    await HiveService.put(HiveService.assignmentsBox, assignmentId, existing);
    _loadFromHive();

    await FirestoreService().addAssignmentComment(
      assignmentId: assignmentId,
      text: text,
      authorName: authorName,
    );
  }

  Future<void> deleteAssignment(String id) async {
    final uid = _currentUid;
    final existing = HiveService.get(HiveService.assignmentsBox, id);
    if (existing == null) return;
    final isCreator = (existing['createdBy'] ?? '').toString() == uid;
    if (!isCreator) return;

    await HiveService.delete(HiveService.assignmentsBox, id);
    _loadFromHive();

    try {
      await FirestoreService().deleteAssignmentSecure(id);
    } catch (e) {
      await SyncService.queueAction(
        action: 'DELETE',
        collection: 'assignments',
        documentId: id,
        data: {},
      );
      debugPrint('Assignment delete callable failed; queued delete fallback: $e');
    }
  }

  void refresh() => _loadFromHive();

  @override
  void dispose() {
    _sub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }
}

// ══════════ FIRM MEMBERS ══════════
final firmMembersProvider = StreamProvider<List<UserModel>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value([]);
  return ref.read(authServiceProvider).watchFirmMembers().map(
        (members) => members
            .where((m) => m.uid != user.uid && m.role.toLowerCase() != 'client')
            .toList(),
      );
});

final cachedFirmMembersProvider = Provider<List<UserModel>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const [];
  final members = ref.read(authServiceProvider).getCachedFirmMembers();
  return members
      .where((m) => m.uid != user.uid && m.role.toLowerCase() != 'client')
      .toList();
});

// ══════════ SOS ALERTS ══════════
final sosAlertsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);
  return ref.read(firestoreServiceProvider).watchSOSAlerts(user.uid);
});

// ══════════ IN-APP NOTIFICATIONS ══════════
final inAppNotificationsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);
  return ref.read(firestoreServiceProvider).watchInAppNotifications();
});

// ══════════ REMINDERS (Hive + Firestore) ══════════
final remindersProvider =
    StateNotifierProvider<RemindersNotifier, List<Reminder>>((ref) {
  final user = ref.watch(currentUserProvider);
  return RemindersNotifier(user?.uid ?? '', user?.role ?? '');
});

class RemindersNotifier extends StateNotifier<List<Reminder>> {
  final String userId;
  final String userRole;
  StreamSubscription? _sub;

  RemindersNotifier(this.userId, this.userRole) : super([]) {
    _loadFromHive();
    _listenToFirestore();
  }

  void _loadFromHive() {
    if (!mounted) return;
    final cached = HiveService.getAll(HiveService.remindersBox);
    final all = cached.map((m) => Reminder.fromMap(m)).toList()
      ..sort((a, b) => a.dueDateTime.compareTo(b.dueDateTime));
    // Show reminders visible to this user
    if (!mounted) return;
    state = all
        .where((r) => r.isVisibleToUser(userId, userRole: userRole))
        .toList();
  }

  void _listenToFirestore() {
    _sub = FirestoreService().watchReminders().listen((data) async {
      final writes = <Future<void>>[];
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          writes.add(HiveService.put(HiveService.remindersBox, id, m));
        }
      }
      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }
      if (!mounted) return;
      _loadFromHive();
    }, onError: (_) {});
  }

  Future<void> addReminder(Reminder r) async {
    final map = r.toMap();
    map['participantIds'] = <String>{r.createdBy, ...r.sharedWithUserIds}.toList();
    await HiveService.put(HiveService.remindersBox, r.id, map);
    await SyncService.queueAction(
      action: 'CREATE',
      collection: 'reminders',
      documentId: r.id,
      data: map,
    );
    _loadFromHive();
  }

  Future<void> updateReminder(Reminder r) async {
    final map = r.toMap();
    map['participantIds'] = <String>{r.createdBy, ...r.sharedWithUserIds}.toList();
    await HiveService.put(HiveService.remindersBox, r.id, map);
    await SyncService.queueAction(
      action: 'UPDATE',
      collection: 'reminders',
      documentId: r.id,
      data: map,
    );
    _loadFromHive();
  }

  Future<void> deleteReminder(String id) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    String creatorUid = '';
    for (final reminder in state) {
      if (reminder.id == id) {
        creatorUid = reminder.createdBy;
        break;
      }
    }

    if (creatorUid.isEmpty) {
      final cached = HiveService.get(HiveService.remindersBox, id);
      if (cached is Map) {
        final cachedMap = cached as Map<dynamic, dynamic>;
        creatorUid = (cachedMap['createdBy'] ?? '').toString();
      }
    }

    if (creatorUid.isEmpty || creatorUid != currentUid) {
      throw Exception('Reminder can only be deleted by the creator of this reminder');
    }

    bool deletedInCloud = false;
    try {
      await FirestoreService().deleteDocument('reminders', id);
      deletedInCloud = true;
    } catch (e) {
      final text = e.toString().toLowerCase();
      final isPermissionError = text.contains('permission-denied') ||
          text.contains('missing or insufficient permissions') ||
          text.contains('unauthenticated');

      if (isPermissionError) {
        throw Exception('Reminder can only be deleted by the creator of this reminder');
      }

      // Offline/transient failure: keep UI responsive and sync later.
      await SyncService.queueAction(
        action: 'DELETE',
        collection: 'reminders',
        documentId: id,
        data: {},
        skipImmediateSync: true,
      );
    }

    if (!deletedInCloud) {
      // Deletion is queued and will complete when connectivity is restored.
    }

    await HiveService.delete(HiveService.remindersBox, id);
    _loadFromHive();
  }

  List<Reminder> get incomplete => state.where((r) => !r.isCompleted).toList();
  List<Reminder> get completed => state.where((r) => r.isCompleted).toList();

  void refresh() => _loadFromHive();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ══════════ NOTICES (Hive + Firestore) ══════════
final noticesProvider =
    StateNotifierProvider<NoticesNotifier, List<Notice>>((ref) {
  return NoticesNotifier();
});

class NoticesNotifier extends StateNotifier<List<Notice>> {
  StreamSubscription? _sub;
  StreamSubscription<User?>? _authSub;
  final Set<String> _pendingDeleteNoticeIds = <String>{};

  bool _isRetryableSyncError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('unavailable') ||
        text.contains('deadline-exceeded') ||
        text.contains('network') ||
        text.contains('timeout') ||
        text.contains('internal');
  }

  NoticesNotifier() : super([]) {
    _loadFromHive();
    _listenToFirestore();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      _sub?.cancel();
      _loadFromHive();
      _listenToFirestore();
    });
  }

  void _loadFromHive() {
    final cached = HiveService.getAll(HiveService.noticesBox);
    state = cached.map((m) => Notice.fromMap(m)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt)); // newest first
  }

  void _listenToFirestore() {
    _sub = FirestoreService().watchNotices().listen((data) async {
      final writes = <Future<void>>[];
      final incomingIds = <String>{};
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          incomingIds.add(id);
        }
        if (id.isNotEmpty && !_pendingDeleteNoticeIds.contains(id)) {
          writes.add(HiveService.put(HiveService.noticesBox, id, m));
        }
      }

      // Once cloud no longer returns an item, consider local delete fully settled.
      _pendingDeleteNoticeIds.removeWhere((id) => !incomingIds.contains(id));

      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }
      _loadFromHive();
    }, onError: (e) {
      debugPrint('Notice stream failed: $e');
    });
  }

  Future<void> addNotice(Notice n) async {
    final map = n.toMap();
    await HiveService.put(HiveService.noticesBox, n.id, map);
    try {
      await FirestoreService().upsertNoticeSecure(map);
    } catch (e) {
      if (_isRetryableSyncError(e)) {
        await SyncService.queueAction(
          action: 'CREATE',
          collection: 'notices',
          documentId: n.id,
          data: map,
        );
      } else {
        rethrow;
      }
    }
    _loadFromHive();
  }

  Future<void> deleteNotice(String id) async {
    final existing = HiveService.get(HiveService.noticesBox, id);
    _pendingDeleteNoticeIds.add(id);
    await HiveService.delete(HiveService.noticesBox, id);
    _loadFromHive();
    try {
      await FirestoreService().deleteNoticeSecure(id);
    } catch (e) {
      if (_isRetryableSyncError(e)) {
        await SyncService.queueAction(
          action: 'DELETE',
          collection: 'notices',
          documentId: id,
          data: {},
        );
      } else {
        _pendingDeleteNoticeIds.remove(id);
        if (existing != null) {
          await HiveService.put(HiveService.noticesBox, id, existing);
        }
        _loadFromHive();
        rethrow;
      }
    }
    _loadFromHive();
  }

  void refresh() => _loadFromHive();

  @override
  void dispose() {
    _sub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }
}

// ══════════ CHAT GROUPS (Hive + Firestore) ══════════
final chatGroupsProvider =
    StateNotifierProvider<ChatGroupsNotifier, List<ChatGroup>>((ref) {
  return ChatGroupsNotifier();
});

class ChatGroupsNotifier extends StateNotifier<List<ChatGroup>> {
  StreamSubscription? _sub;

  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  ChatGroupsNotifier() : super([]) {
    _loadFromHive();
    _listenToFirestore();
  }

  dynamic _sanitizeForHive(dynamic value) {
    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k, _sanitizeForHive(v)));
    }
    if (value is List) {
      return value.map(_sanitizeForHive).toList();
    }
    return value;
  }

  void _loadFromHive() {
    final uid = _currentUid;
    final cached = HiveService.getAll(HiveService.chatGroupsBox);
    state = cached
        .where((m) {
          if (uid.isEmpty) return false;
          final memberIds = List<String>.from(m['memberIds'] ?? const []);
          final hiddenFor = List<String>.from(m['hiddenForUserIds'] ?? const []);
          return memberIds.contains(uid) && !hiddenFor.contains(uid);
        })
        .map((m) => ChatGroup.fromMap(m))
        .toList()
      ..sort((a, b) {
        final at = a.lastMessageTime ?? a.createdAt;
        final bt = b.lastMessageTime ?? b.createdAt;
        return bt.compareTo(at); // most recent first
      });
  }

  void _listenToFirestore() {
    _sub = FirestoreService().watchChatGroups().listen((data) async {
      final writes = <Future<void>>[];
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          final safe =
              Map<String, dynamic>.from(_sanitizeForHive(m) as Map);
          writes.add(HiveService.put(HiveService.chatGroupsBox, id, safe));
        }
      }
      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }
      _loadFromHive();
    }, onError: (_) {});
  }

  Future<void> addChatGroup(ChatGroup g) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    final map = g.toMap();
    final members = <String>{
      ...List<String>.from(map['memberIds'] ?? const []),
      uid
    };
    map['memberIds'] = members.toList();
    map['participantIds'] = members.toList();
    map['updatedAt'] = DateTime.now().toIso8601String();
    await HiveService.put(HiveService.chatGroupsBox, g.id, map);
    await FirestoreService().upsertChatGroupSecure(map);
    _loadFromHive();
  }

  Future<void> deleteChatForMe(String id) async {
    await HiveService.delete(HiveService.chatGroupsBox, id);
    await FirestoreService().deleteChatForMeSecure(id);
    _loadFromHive();
  }

  Future<void> deleteChatForEveryone(String id) async {
    await HiveService.delete(HiveService.chatGroupsBox, id);
    await FirestoreService().deleteChatForEveryoneSecure(id);
    _loadFromHive();
  }

  Future<void> clearChatForMe(String id) async {
    final existing = HiveService.get(HiveService.chatGroupsBox, id);
    if (existing == null) return;
    final uid = _currentUid;
    if (uid.isEmpty) return;

    final clearMap = Map<String, dynamic>.from(existing['clearedAtByUser'] ?? const {});
    clearMap[uid] = DateTime.now().toIso8601String();
    existing['clearedAtByUser'] = clearMap;
    await HiveService.put(HiveService.chatGroupsBox, id, existing);
    await FirestoreService().clearChatForMeSecure(id);
    _loadFromHive();
  }

  Future<void> updateChatGroup(ChatGroup g) async {
    final map = g.toMap();
    final members = <String>{...List<String>.from(map['memberIds'] ?? const [])};
    if (g.createdBy.isNotEmpty) {
      members.add(g.createdBy);
    }
    map['memberIds'] = members.toList();
    map['participantIds'] = members.toList();
    map['updatedAt'] = DateTime.now().toIso8601String();

    await HiveService.put(HiveService.chatGroupsBox, g.id, map);
    await FirestoreService().upsertChatGroupSecure(map);
    _loadFromHive();
  }

  void refresh() => _loadFromHive();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
