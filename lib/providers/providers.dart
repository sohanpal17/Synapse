import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
    if (fbUser == null) {
      state = null;
      return;
    }

    final currentState = state;

    final cached = _authService.getCachedUser();
    if (cached != null && cached.uid == fbUser.uid) {
      state = cached;
    }

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

    if (currentState != null && currentState.uid == fbUser.uid) {
      state = currentState;
      return;
    }

    // Avoid creating a phantom default-role profile. If no reliable profile exists,
    // force sign-out so the app returns to Login instead of opening wrong dashboards.
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('Failed to sign out after missing profile: $e');
    }
    state = null;
  }

  void setUser(UserModel user) => state = user;
  void clear() => state = null;

  @override
  void dispose() {
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

    final clients = List<String>.from(map['clientIds'] ?? const []);
    return clients.contains(uid);
  }

  List<String> _computeCaseParticipants(Map<String, dynamic> map) {
    final participants = <String>{
      ...List<String>.from(map['participantIds'] ?? const []),
      ...List<String>.from(map['assignedLawyerIds'] ?? const []),
      ...List<String>.from(map['assignedInternIds'] ?? const []),
      ...List<String>.from(map['assignedMemberIds'] ?? const []),
      ...List<String>.from(map['clientIds'] ?? const []),
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

  Future<void> updateCase(String cino, Map<String, dynamic> updates) async {
    final existing = HiveService.get(HiveService.casesBox, cino);
    if (existing != null) {
      existing['ownerUid'] = _currentUid;
      existing.addAll(updates);
      existing['participantIds'] = _computeCaseParticipants(existing);
      existing['updatedAt'] = DateTime.now().toIso8601String();
      await HiveService.put(HiveService.casesBox, cino, existing);
      await SyncService.queueAction(
        action: 'UPDATE',
        collection: 'cases',
        documentId: cino,
        data: existing,
      );
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
      final isOwner = t['createdBy'] == uid;
      final isPublic = t['isPublic'] == true || t['visibility'] == 'everyone';
      final isAssigned = assigned.contains(uid);

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
      final writes = <Future<void>>[];
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          writes.add(HiveService.put(HiveService.tasksBox, id, m));
        }
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
    }..removeWhere((e) => e.trim().isEmpty);
    final local = Map<String, dynamic>.from(task)
      ..['participantIds'] = participants.toList();

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
      existing.addAll(updates);
      final participants = <String>{
        _currentUid,
        ...List<String>.from(existing['participantIds'] ?? const []),
        ...List<String>.from(existing['assignedJuniorIds'] ?? const []),
      }..removeWhere((e) => e.trim().isEmpty);
      existing['participantIds'] = participants.toList();
      existing['updatedAt'] = DateTime.now().toIso8601String();
      await HiveService.put(HiveService.tasksBox, id, existing);
      await SyncService.queueAction(
        action: 'UPDATE',
        collection: 'tasks',
        documentId: id,
        data: existing,
      );
      _load();
    }
  }

  Future<void> deleteTask(String id) async {
    await HiveService.delete(HiveService.tasksBox, id);
    await SyncService.queueAction(
      action: 'DELETE',
      collection: 'tasks',
      documentId: id,
      data: {},
    );
    _load();
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
      final writes = <Future<void>>[];
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          writes.add(HiveService.put(HiveService.assignmentsBox, id, m));
        }
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
      ..['participantIds'] = participants.toList();

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

    existing.addAll(updates);
    final assignees = _assignmentAssigneeIds(existing);
    final participants = <String>{
      _currentUid,
      ...assignees,
      ...List<String>.from(existing['participantIds'] ?? const []),
    }..removeWhere((e) => e.isEmpty);
    existing['participantIds'] = participants.toList();
    existing['updatedAt'] = DateTime.now().toIso8601String();
    await HiveService.put(HiveService.assignmentsBox, id, existing);
    await SyncService.queueAction(
      action: 'UPDATE',
      collection: 'assignments',
      documentId: id,
      data: existing,
    );
    _loadFromHive();
  }

  Future<void> deleteAssignment(String id) async {
    await HiveService.delete(HiveService.assignmentsBox, id);
    await SyncService.queueAction(
      action: 'DELETE',
      collection: 'assignments',
      documentId: id,
      data: {},
    );
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

// ══════════ FIRM MEMBERS ══════════
final firmMembersProvider = StreamProvider<List<UserModel>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value([]);
  return ref.read(authServiceProvider).watchFirmMembers().map(
        (members) => members.where((m) => m.uid != user.uid).toList(),
      );
});

// ══════════ SOS ALERTS ══════════
final sosAlertsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);
  return ref.read(firestoreServiceProvider).watchSOSAlerts(user.uid);
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
    await HiveService.delete(HiveService.remindersBox, id);
    await SyncService.queueAction(
      action: 'DELETE',
      collection: 'reminders',
      documentId: id,
      data: {},
    );
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

  NoticesNotifier() : super([]) {
    _loadFromHive();
    _listenToFirestore();
  }

  void _loadFromHive() {
    final cached = HiveService.getAll(HiveService.noticesBox);
    state = cached.map((m) => Notice.fromMap(m)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt)); // newest first
  }

  void _listenToFirestore() {
    _sub = FirestoreService().watchNotices().listen((data) async {
      final writes = <Future<void>>[];
      for (final m in data) {
        final id = m['id'] as String? ?? '';
        if (id.isNotEmpty) {
          writes.add(HiveService.put(HiveService.noticesBox, id, m));
        }
      }
      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }
      _loadFromHive();
    }, onError: (_) {});
  }

  Future<void> addNotice(Notice n) async {
    final map = n.toMap();
    await HiveService.put(HiveService.noticesBox, n.id, map);
    await SyncService.queueAction(
      action: 'CREATE',
      collection: 'notices',
      documentId: n.id,
      data: map,
    );
    _loadFromHive();
  }

  Future<void> deleteNotice(String id) async {
    await HiveService.delete(HiveService.noticesBox, id);
    await SyncService.queueAction(
      action: 'DELETE',
      collection: 'notices',
      documentId: id,
      data: {},
    );
    _loadFromHive();
  }

  void refresh() => _loadFromHive();

  @override
  void dispose() {
    _sub?.cancel();
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

  void _loadFromHive() {
    final uid = _currentUid;
    final cached = HiveService.getAll(HiveService.chatGroupsBox);
    state = cached
        .where((m) {
          if (uid.isEmpty) return false;
          final memberIds = List<String>.from(m['memberIds'] ?? const []);
          return memberIds.contains(uid);
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
          writes.add(HiveService.put(HiveService.chatGroupsBox, id, m));
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
    await HiveService.put(HiveService.chatGroupsBox, g.id, map);
    await SyncService.queueAction(
      action: 'CREATE',
      collection: 'chatGroups',
      documentId: g.id,
      data: map,
    );
    _loadFromHive();
  }

  Future<void> deleteChatGroup(String id) async {
    await HiveService.delete(HiveService.chatGroupsBox, id);
    await SyncService.queueAction(
      action: 'DELETE',
      collection: 'chatGroups',
      documentId: id,
      data: {},
    );
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
    await SyncService.queueAction(
      action: 'UPDATE',
      collection: 'chatGroups',
      documentId: g.id,
      data: map,
    );
    _loadFromHive();
  }

  void refresh() => _loadFromHive();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
