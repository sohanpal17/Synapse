import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/case_model.dart';
import 'sync_service.dart';

/// Handles all Firestore read/write operations
class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-south1');

  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  String _sanitizeCaseId(String cino) =>
      cino.replaceAll('/', '_').replaceAll(' ', '_');

  String _caseDocIdForUser(String uid, String cino) => '${uid}_${_sanitizeCaseId(cino)}';

  Map<String, dynamic> _withOwnership(Map<String, dynamic> data) {
    final uid = _currentUid;
    if (uid.isEmpty) return Map<String, dynamic>.from(data);
    final map = Map<String, dynamic>.from(data);
    map.putIfAbsent('ownerUid', () => uid);
    return map;
  }

  Map<String, dynamic> _withCaseParticipants(Map<String, dynamic> data) {
    final uid = _currentUid;
    final map = _withOwnership(data);

    final ownerUid = (map['ownerUid'] as String? ?? uid).trim();
    final participants = <String>{};
    if (ownerUid.isNotEmpty) {
      participants.add(ownerUid);
    }

    participants.addAll(
      List<String>.from(map['participantIds'] ?? const []),
    );
    participants.addAll(
      List<String>.from(map['assignedLawyerIds'] ?? const []),
    );
    participants.addAll(
      List<String>.from(map['assignedInternIds'] ?? const []),
    );
    participants.addAll(
      List<String>.from(map['assignedMemberIds'] ?? const []),
    );

    participants.removeWhere((id) => id.trim().isEmpty);
    map['participantIds'] = participants.toList();
    return map;
  }

  Map<String, dynamic> _withParticipants(Map<String, dynamic> data) {
    final uid = _currentUid;
    if (uid.isEmpty) return Map<String, dynamic>.from(data);

    final map = Map<String, dynamic>.from(data);
    final participants = <String>{uid};

    participants.addAll(
      List<String>.from(map['participantIds'] ?? const []),
    );
    participants.addAll(
      List<String>.from(map['assignedJuniorIds'] ?? const []),
    );
    participants.addAll(
      List<String>.from(map['assignedToIds'] ?? const []),
    );

    final assignedTo = (map['assignedToId'] as String? ?? '').trim();
    if (assignedTo.isNotEmpty) {
      participants.add(assignedTo);
    }

    map['participantIds'] = participants.toList();
    return map;
  }

  Map<String, dynamic> _withNoticeParticipants(Map<String, dynamic> data) {
    final uid = _currentUid;
    final map = Map<String, dynamic>.from(data);
    if (uid.isEmpty) return map;

    map['ownerUid'] = (map['ownerUid'] as String? ?? uid).trim().isEmpty
      ? uid
      : map['ownerUid'];
    map['createdBy'] = (map['createdBy'] as String? ?? uid).trim().isEmpty
      ? uid
      : map['createdBy'];

    final participants = <String>{uid};
    participants.addAll(List<String>.from(map['participantIds'] ?? const []));

    final authorId = (map['authorId'] as String? ?? '').trim();
    if (authorId.isNotEmpty) {
      participants.add(authorId);
    }

    map['participantIds'] = participants.toList();
    return map;
  }

  List<Map<String, dynamic>> _mergeByDocumentId(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> primary,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> secondary,
  ) {
    final merged = <String, Map<String, dynamic>>{};

    for (final doc in [...primary, ...secondary]) {
      final data = Map<String, dynamic>.from(doc.data());
      data.putIfAbsent('id', () => doc.id);
      merged[doc.id] = data;
    }

    return merged.values.toList();
  }

  // ══════════════════════════════════════
  //                CASES
  // ══════════════════════════════════════

  /// Create or update a single case
  Future<void> upsertCase(CaseModel c) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    final docId = _caseDocIdForUser(uid, c.cino);
    final map = _withCaseParticipants(c.toMap());
    await _db
        .collection('cases')
        .doc(docId)
      .set(map, SetOptions(merge: true));
  }

  /// Batch upsert multiple cases (used during eCourts import)
  Future<void> upsertCases(List<CaseModel> cases, {String? source}) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    // Firestore batch limit is 500, so we chunk
    const batchSize = 450;
    for (int i = 0; i < cases.length; i += batchSize) {
      final batch = _db.batch();
      final chunk = cases.skip(i).take(batchSize);

      for (final c in chunk) {
        final docId = _caseDocIdForUser(uid, c.cino);
        final ref = _db.collection('cases').doc(docId);
        final map = _withCaseParticipants(c.toMap());
        if (source != null && source.isNotEmpty) {
          map['source'] = source;
        }
        batch.set(ref, map, SetOptions(merge: true));
      }

      await batch.commit();
    }
  }

  /// Get all cases for the firm (one-time fetch)
  Future<List<CaseModel>> getCases() async {
    final uid = _currentUid;
    if (uid.isEmpty) return [];
    final snapshot = await _db
        .collection('cases')
      .where('participantIds', arrayContains: uid)
        .get();

    return snapshot.docs
        .map((doc) => CaseModel.fromMap(doc.data()))
        .toList();
  }

  /// Real-time stream of all firm cases
  Stream<List<CaseModel>> watchCases() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);
    return _db
        .collection('cases')
      .where('participantIds', arrayContains: uid)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => CaseModel.fromMap(doc.data()))
            .toList());
  }

  /// Real-time stream of raw case maps (preserves non-model fields like source)
  Stream<List<Map<String, dynamic>>> watchCasesRaw() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);
    return _db
        .collection('cases')
        .where('participantIds', arrayContains: uid)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data.putIfAbsent('cino', () => doc.id);
        return data;
      }).toList();
    });
  }

  /// Get active cases only
  Future<List<CaseModel>> getActiveCases() async {
    final uid = _currentUid;
    if (uid.isEmpty) return [];
    final snapshot = await _db
        .collection('cases')
      .where('participantIds', arrayContains: uid)
        .get();

    return snapshot.docs
        .map((doc) => CaseModel.fromMap(doc.data()))
        .where((c) => !c.isClosed)
        .toList();
  }

  /// Delete a case
  Future<void> deleteCase(String cino) async {
    await SyncService.queueAction(
      action: 'DELETE',
      collection: 'cases',
      documentId: cino,
      data: {},
    );
  }

  /// Update team members for a case through a callable (bypasses client ACL write limits).
  Future<void> updateCaseTeamMembers({
    required String cino,
    required List<String> memberIds,
    List<String> lawyerIds = const [],
    List<String> internIds = const [],
  }) async {
    await _functions.httpsCallable('updateCaseTeamMembers').call({
      'cino': cino,
      'memberIds': memberIds,
      'lawyerIds': lawyerIds,
      'internIds': internIds,
    });
  }

  /// Append a document entry to a case via callable (owner/participant/admin).
  Future<void> appendCaseDocument({
    required String cino,
    required Map<String, dynamic> document,
  }) async {
    await _functions.httpsCallable('appendCaseDocument').call({
      'cino': cino,
      'document': document,
    });
  }

  /// Delete a document entry from a case via callable (owner/participant/admin).
  Future<void> deleteCaseDocument({
    required String cino,
    String? documentId,
    String? documentUrl,
  }) async {
    await _functions.httpsCallable('deleteCaseDocument').call({
      'cino': cino,
      'documentId': documentId ?? '',
      'documentUrl': documentUrl ?? '',
    });
  }

  // ══════════════════════════════════════
  //                TASKS
  // ══════════════════════════════════════

  /// Create or update a task
  Future<void> upsertTask(Map<String, dynamic> task) async {
    final map = _withParticipants(task);
    await _db
        .collection('tasks')
      .doc(map['id'])
      .set(map, SetOptions(merge: true));
  }

  /// Get all tasks for the firm
  Future<List<Map<String, dynamic>>> getTasks() async {
    final uid = _currentUid;
    if (uid.isEmpty) return [];
    final snapshots = await Future.wait([
      _db.collection('tasks').where('participantIds', arrayContains: uid).get(),
      _db.collection('tasks').where('assignedJuniorIds', arrayContains: uid).get(),
      _db.collection('tasks').where('assignedToIds', arrayContains: uid).get(),
      _db.collection('tasks').where('assignedToId', isEqualTo: uid).get(),
      _db.collection('tasks').where('createdBy', isEqualTo: uid).get(),
      _db.collection('tasks').where('isPublic', isEqualTo: true).get(),
    ]);

    return _mergeByDocumentId(
      [
        ...snapshots[0].docs,
        ...snapshots[1].docs,
        ...snapshots[2].docs,
        ...snapshots[3].docs,
        ...snapshots[4].docs,
      ],
      snapshots[5].docs,
    );
  }

  /// Real-time stream of tasks
  Stream<List<Map<String, dynamic>>> watchTasks() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);

    final participantStream = _db
        .collection('tasks')
        .where('participantIds', arrayContains: uid)
        .snapshots();
    final assignedStream = _db
        .collection('tasks')
        .where('assignedJuniorIds', arrayContains: uid)
        .snapshots();
    final assignedManyStream = _db
      .collection('tasks')
      .where('assignedToIds', arrayContains: uid)
      .snapshots();
    final assignedSingleStream = _db
      .collection('tasks')
      .where('assignedToId', isEqualTo: uid)
      .snapshots();
    final createdByStream = _db
      .collection('tasks')
      .where('createdBy', isEqualTo: uid)
      .snapshots();
    final publicStream = _db
        .collection('tasks')
        .where('isPublic', isEqualTo: true)
        .snapshots();

    final controller = StreamController<List<Map<String, dynamic>>>();
    List<QueryDocumentSnapshot<Map<String, dynamic>>> participantDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> assignedDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> assignedManyDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> assignedSingleDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> createdByDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> publicDocs = const [];

    void emitMerged() {
      controller.add(_mergeByDocumentId(
        [
          ...participantDocs,
          ...assignedDocs,
          ...assignedManyDocs,
          ...assignedSingleDocs,
          ...createdByDocs,
        ],
        publicDocs,
      ));
    }

    final subA = participantStream.listen(
      (snapshot) {
        participantDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subB = assignedStream.listen(
      (snapshot) {
        assignedDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subC = assignedManyStream.listen(
      (snapshot) {
        assignedManyDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subD = assignedSingleStream.listen(
      (snapshot) {
        assignedSingleDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subE = createdByStream.listen(
      (snapshot) {
        createdByDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subF = publicStream.listen(
      (snapshot) {
        publicDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );

    controller.onCancel = () async {
      await subA.cancel();
      await subB.cancel();
      await subC.cancel();
      await subD.cancel();
      await subE.cancel();
      await subF.cancel();
    };

    return controller.stream;
  }

  /// Delete a task
  Future<void> deleteTask(String taskId) async {
    await _db.collection('tasks').doc(taskId).delete();
  }

  /// Delete task via callable (creator/admin enforced on backend)
  Future<void> deleteTaskSecure(String taskId) async {
    await _functions.httpsCallable('deleteTask').call({
      'taskId': taskId,
    });
  }

  /// Update task status via callable (server-side ACL)
  Future<void> updateTaskStatus(String taskId, String status) async {
    await _functions.httpsCallable('updateTaskStatus').call({
      'taskId': taskId,
      'status': status,
    });
  }

  /// Update task details via callable (creator/admin enforced on backend)
  Future<void> updateTaskDetails(
      String taskId, Map<String, dynamic> updates) async {
    await _functions.httpsCallable('updateTaskDetails').call({
      'taskId': taskId,
      'updates': updates,
    });
  }

  /// Mark task as viewed (direct write allowed for assignees)
  Future<void> notifyTaskViewed({
    required String taskId,
    required String taskTitle,
    required String creatorUid,
    required String viewerUid,
    required String viewerName,
  }) async {
    await _functions.httpsCallable('markTaskViewed').call({
      'taskId': taskId,
      'viewerName': viewerName,
    });
  }

  /// Update fields that assignees are permitted to write (viewedBy, isEscalated, autoEscalate).
  Future<void> updateTaskAssignableFields(
      String taskId, Map<String, dynamic> updates) async {
    await _functions.httpsCallable('updateTaskAssignableFields').call({
      'taskId': taskId,
      'updates': updates,
    });
  }

  /// Clear completed tasks only for current user.
  Future<void> clearCompletedTasksForUser(List<String> taskIds) async {
    await _functions.httpsCallable('clearCompletedTasksForUser').call({
      'taskIds': taskIds,
    });
  }

  Future<void> addTaskComment({
    required String taskId,
    required String text,
    required String authorName,
  }) async {
    await _functions.httpsCallable('addTaskComment').call({
      'taskId': taskId,
      'text': text,
      'authorName': authorName,
    });
  }

  // ══════════════════════════════════════
  //             ASSIGNMENTS
  // ══════════════════════════════════════

  /// Mark assignment as viewed
  Future<void> notifyAssignmentViewed({
    required String assignmentId,
    required String assignmentTitle,
    required String creatorUid,
    required String viewerUid,
    required String viewerName,
  }) async {
    await _functions.httpsCallable('markAssignmentViewed').call({
      'assignmentId': assignmentId,
      'viewerName': viewerName,
    });
  }

  /// Update fields that assignees are permitted to write in assignments.
  Future<void> updateAssignmentAssignableFields(
      String assignmentId, Map<String, dynamic> updates) async {
    await _functions.httpsCallable('updateAssignmentAssignableFields').call({
      'assignmentId': assignmentId,
      'updates': updates,
    });
  }

  /// Clear completed assignments only for current user.
  Future<void> clearCompletedAssignmentsForUser(
      List<String> assignmentIds) async {
    await _functions.httpsCallable('clearCompletedAssignmentsForUser').call({
      'assignmentIds': assignmentIds,
    });
  }

  Future<void> addAssignmentComment({
    required String assignmentId,
    required String text,
    required String authorName,
  }) async {
    await _functions.httpsCallable('addAssignmentComment').call({
      'assignmentId': assignmentId,
      'text': text,
      'authorName': authorName,
    });
  }

  /// Create or update an assignment
  Future<void> upsertAssignment(Map<String, dynamic> assignment) async {
    final map = _withParticipants(assignment);
    await _db
        .collection('assignments')
      .doc(map['id'])
      .set(map, SetOptions(merge: true));
  }

  /// Get all assignments for the firm
  Future<List<Map<String, dynamic>>> getAssignments() async {
    final uid = _currentUid;
    if (uid.isEmpty) return [];
    final snapshots = await Future.wait([
      _db.collection('assignments').where('participantIds', arrayContains: uid).get(),
      _db.collection('assignments').where('assignedToIds', arrayContains: uid).get(),
      _db.collection('assignments').where('assignedToId', isEqualTo: uid).get(),
    ]);

    return _mergeByDocumentId(
      [...snapshots[0].docs, ...snapshots[1].docs],
      snapshots[2].docs,
    );
  }

  /// Real-time stream of assignments
  Stream<List<Map<String, dynamic>>> watchAssignments() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);

    final participantStream = _db
        .collection('assignments')
        .where('participantIds', arrayContains: uid)
        .snapshots();
    final assignedManyStream = _db
        .collection('assignments')
        .where('assignedToIds', arrayContains: uid)
        .snapshots();
    final assignedSingleStream = _db
        .collection('assignments')
        .where('assignedToId', isEqualTo: uid)
        .snapshots();

    final controller = StreamController<List<Map<String, dynamic>>>();
    List<QueryDocumentSnapshot<Map<String, dynamic>>> participantDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> assignedManyDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> assignedSingleDocs = const [];

    void emitMerged() {
      controller.add(_mergeByDocumentId(
        [...participantDocs, ...assignedManyDocs],
        assignedSingleDocs,
      ));
    }

    final subA = participantStream.listen(
      (snapshot) {
        participantDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subB = assignedManyStream.listen(
      (snapshot) {
        assignedManyDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subC = assignedSingleStream.listen(
      (snapshot) {
        assignedSingleDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );

    controller.onCancel = () async {
      await subA.cancel();
      await subB.cancel();
      await subC.cancel();
    };

    return controller.stream;
  }

  /// Delete assignment via callable (creator/admin enforced on backend)
  Future<void> deleteAssignmentSecure(String assignmentId) async {
    await _functions.httpsCallable('deleteAssignment').call({
      'assignmentId': assignmentId,
    });
  }

  /// Update assignment status via callable (server-side ACL)
  Future<void> updateAssignmentStatus(String assignmentId, String status) async {
    await _functions.httpsCallable('updateAssignmentStatus').call({
      'assignmentId': assignmentId,
      'status': status,
    });
  }

  /// Update assignment details via callable (creator/admin enforced on backend)
  Future<void> updateAssignmentDetails(
      String assignmentId, Map<String, dynamic> updates) async {
    await _functions.httpsCallable('updateAssignmentDetails').call({
      'assignmentId': assignmentId,
      'updates': updates,
    });
  }

  // ══════════════════════════════════════
  //              NOTICES
  // ══════════════════════════════════════

  /// Create a notice
  Future<void> createNotice(Map<String, dynamic> notice) async {
    final map = _withNoticeParticipants(notice);
    await _db.collection('notices').doc(notice['id']).set(map);
  }

  /// Create/update notice via callable (server-side ACL + participant expansion)
  Future<void> upsertNoticeSecure(Map<String, dynamic> notice) async {
    await _functions.httpsCallable('upsertNotice').call({
      'notice': notice,
    });
  }

  /// Get all notices for the firm
  Future<List<Map<String, dynamic>>> getNotices() async {
    final uid = _currentUid;
    if (uid.isEmpty) return [];

    final snapshots = await Future.wait([
      _db
          .collection('notices')
          .where('participantIds', arrayContains: uid)
          .get(),
      _db
          .collection('notices')
          .where('authorId', isEqualTo: uid)
          .get(),
    ]);

    return _mergeByDocumentId(snapshots[0].docs, snapshots[1].docs);
  }

  /// Real-time stream of notices
  Stream<List<Map<String, dynamic>>> watchNotices() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);

    final participantStream = _db
        .collection('notices')
        .where('participantIds', arrayContains: uid)
        .snapshots();
    final authorStream = _db
        .collection('notices')
        .where('authorId', isEqualTo: uid)
        .snapshots();

    final controller = StreamController<List<Map<String, dynamic>>>();
    List<QueryDocumentSnapshot<Map<String, dynamic>>> participantDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> authorDocs = const [];

    void emitMerged() {
      controller.add(_mergeByDocumentId(participantDocs, authorDocs));
    }

    final subA = participantStream.listen(
      (snapshot) {
        participantDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subB = authorStream.listen(
      (snapshot) {
        authorDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );

    controller.onCancel = () async {
      await subA.cancel();
      await subB.cancel();
    };

    return controller.stream;
  }

  /// Delete a notice
  Future<void> deleteNotice(String noticeId) async {
    await _db.collection('notices').doc(noticeId).delete();
  }

  /// Delete notice via callable (author/admin enforced on backend)
  Future<void> deleteNoticeSecure(String noticeId) async {
    await _functions.httpsCallable('deleteNotice').call({
      'noticeId': noticeId,
    });
  }

  // ══════════════════════════════════════
  //            IN-APP NOTIFICATIONS
  // ══════════════════════════════════════

  /// Real-time stream of notifications for current user.
  Stream<List<Map<String, dynamic>>> watchInAppNotifications() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);

    return _db
        .collection('notifications')
        .where('recipientUid', isEqualTo: uid)
        .snapshots()
        .map((snapshot) {
      final items = snapshot.docs
          .map((d) => {
                'id': d.id,
                ...d.data(),
              })
          .toList();

      items.sort((a, b) {
        final aRaw = (a['createdAt'] ?? '').toString();
        final bRaw = (b['createdAt'] ?? '').toString();
        return bRaw.compareTo(aRaw);
      });
      return items;
    });
  }

  Future<void> markNotificationRead(String notificationId) async {
    await _db.collection('notifications').doc(notificationId).set({
      'isRead': true,
      'readAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  // ══════════════════════════════════════
  //             CHAT GROUPS
  // ══════════════════════════════════════

  /// Create a chat group
  Future<void> createChatGroup(Map<String, dynamic> group) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    final map = Map<String, dynamic>.from(group);
    final members = <String>{
      uid,
      (map['createdBy'] ?? '').toString(),
      ...List<String>.from(map['memberIds'] ?? const []),
      ...List<String>.from(map['participantIds'] ?? const []),
    }..removeWhere((e) => e.trim().isEmpty);

    map['createdBy'] = (map['createdBy'] ?? '').toString().trim().isEmpty
        ? uid
        : map['createdBy'];
    map['memberIds'] = members.toList();
    map['participantIds'] = members.toList();

    await _db.collection('chatGroups').doc(map['id']).set(map);
  }

  /// Get all chat groups for the firm
  Stream<List<Map<String, dynamic>>> watchChatGroups() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);
    return _db
        .collection('chatGroups')
        .where('memberIds', arrayContains: uid)
        .snapshots()
        .map((s) => s.docs
            .map((d) => d.data())
            .where((m) => !List<String>.from(m['hiddenForUserIds'] ?? const [])
                .contains(uid))
            .toList());
  }

  /// Delete a chat group
  Future<void> deleteChatGroup(String groupId) async {
    // Delete all messages in the group first
    final messages = await _db
        .collection('chatGroups')
        .doc(groupId)
        .collection('messages')
        .get();

    final batch = _db.batch();
    for (final msg in messages.docs) {
      batch.delete(msg.reference);
    }
    batch.delete(_db.collection('chatGroups').doc(groupId));
    await batch.commit();
  }

  /// Create/update chat group via callable with creator-only update enforcement.
  Future<void> upsertChatGroupSecure(Map<String, dynamic> group) async {
    await _functions.httpsCallable('upsertChatGroup').call({
      'group': group,
    });
  }

  /// Hide chat group only for current user.
  Future<void> deleteChatForMeSecure(String groupId) async {
    await _functions.httpsCallable('deleteChatForMe').call({
      'groupId': groupId,
    });
  }

  /// Delete chat for everyone (creator only).
  Future<void> deleteChatForEveryoneSecure(String groupId) async {
    await _functions.httpsCallable('deleteChatForEveryone').call({
      'groupId': groupId,
    });
  }

  /// Clear chat history only for current user.
  Future<void> clearChatForMeSecure(String groupId) async {
    await _functions.httpsCallable('clearChatForMe').call({
      'groupId': groupId,
    });
  }

  // ══════════════════════════════════════
  //              MESSAGES
  // ══════════════════════════════════════

  /// Send a message to a chat group
  Future<void> sendMessage(Map<String, dynamic> message) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    final map = Map<String, dynamic>.from(message);
    final groupId = map['chatGroupId'];
    final groupRef = _db.collection('chatGroups').doc(groupId);
    final groupDoc = await groupRef.get();
    if (!groupDoc.exists) return;

    final memberIds = List<String>.from(groupDoc.data()?['memberIds'] ?? const []);
    if (!memberIds.contains(uid)) {
      throw StateError('You are not allowed to send messages to this chat.');
    }

    final messageRef = groupRef.collection('messages').doc(map['id']);
    final clientTs = map['timestamp'];

    await _db.runTransaction((txn) async {
      final groupSnap = await txn.get(groupRef);
      if (!groupSnap.exists) {
        throw StateError('Chat group no longer exists.');
      }

      final latestMembers =
          List<String>.from(groupSnap.data()?['memberIds'] ?? const []);
      if (!latestMembers.contains(uid)) {
        throw StateError('You are not allowed to send messages to this chat.');
      }

      map['senderId'] = uid;
      map['clientTimestamp'] = clientTs;
      map['timestamp'] = FieldValue.serverTimestamp();

      txn.set(messageRef, map);
      txn.update(groupRef, {
        'lastMessage': map['content'],
        'lastMessageTime': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Real-time stream of messages for a chat group
  Stream<List<Map<String, dynamic>>> watchMessages(String chatGroupId) {
    return _db
        .collection('chatGroups')
        .doc(chatGroupId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  // ══════════════════════════════════════
  //                SOS
  // ══════════════════════════════════════

  /// Send an SOS alert
  Future<void> sendSOS(Map<String, dynamic> sos) async {
    final map = Map<String, dynamic>.from(sos);
    final participants = <String>{
      (map['sentBy'] ?? '').toString(),
      ...List<String>.from(map['participantIds'] ?? const []),
      ...List<String>.from(map['recipientIds'] ?? const []),
    }..removeWhere((e) => e.trim().isEmpty);
    map['participantIds'] = participants.toList();

    await _db.collection('sos_alerts').doc(map['id']).set(map);
  }

  /// Get SOS alerts for a user (recipient)
  Stream<List<Map<String, dynamic>>> watchSOSAlerts(String userId) {
    return _db
        .collection('sos_alerts')
        .where('participantIds', arrayContains: userId)
        .limit(20)
        .snapshots()
        .map((s) {
          final items = s.docs.map((d) => d.data()).toList();
          DateTime parseTs(Map<String, dynamic> m) {
            final raw = m['timestamp'] ?? m['createdAt'];
            if (raw is Timestamp) return raw.toDate();
            if (raw is DateTime) return raw;
            if (raw is String) {
              return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
            }
            return DateTime.fromMillisecondsSinceEpoch(0);
          }

          items.sort((a, b) => parseTs(b).compareTo(parseTs(a)));
          return items;
        });
  }

  // ══════════════════════════════════════
  //          REMINDERS / CALENDAR
  // ══════════════════════════════════════

  /// Save a reminder
  Future<void> upsertReminder(Map<String, dynamic> reminder) async {
    final map = Map<String, dynamic>.from(reminder);
    final participants = <String>{
      (map['createdBy'] ?? '').toString(),
      ...List<String>.from(map['participantIds'] ?? const []),
      ...List<String>.from(map['sharedWithUserIds'] ?? const []),
    }..removeWhere((e) => e.trim().isEmpty);
    map['participantIds'] = participants.toList();

    await _db
        .collection('reminders')
        .doc(map['id'])
        .set(map, SetOptions(merge: true));
  }

  /// Get reminders for the firm
  Future<List<Map<String, dynamic>>> getReminders() async {
    final uid = _currentUid;
    if (uid.isEmpty) return [];

    final snapshots = await Future.wait([
      _db.collection('reminders').where('participantIds', arrayContains: uid).get(),
      _db.collection('reminders').where('createdBy', isEqualTo: uid).get(),
    ]);

    return _mergeByDocumentId(snapshots[0].docs, snapshots[1].docs);
  }

  /// Real-time stream of reminders
  Stream<List<Map<String, dynamic>>> watchReminders() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);

    final participantStream = _db
        .collection('reminders')
        .where('participantIds', arrayContains: uid)
        .snapshots();
    final createdByStream = _db
        .collection('reminders')
        .where('createdBy', isEqualTo: uid)
        .snapshots();

    final controller = StreamController<List<Map<String, dynamic>>>();
    List<QueryDocumentSnapshot<Map<String, dynamic>>> participantDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> createdByDocs = const [];

    void emitMerged() {
      controller.add(_mergeByDocumentId(participantDocs, createdByDocs));
    }

    final subA = participantStream.listen(
      (snapshot) {
        participantDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );
    final subB = createdByStream.listen(
      (snapshot) {
        createdByDocs = snapshot.docs;
        emitMerged();
      },
      onError: controller.addError,
    );

    controller.onCancel = () async {
      await subA.cancel();
      await subB.cancel();
    };

    return controller.stream;
  }

  // ══════════════════════════════════════
  //         GENERIC OPERATIONS
  //   (Used by SyncService for queue)
  // ══════════════════════════════════════

  /// Set any document (used by sync engine)
  Future<void> setDocument(
      String collection, String docId, Map<String, dynamic> data,
      {String action = 'UPDATE'}) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    if (collection == 'notices') {
      await upsertNoticeSecure({
        ...data,
        'id': docId,
      });
      return;
    }

    final effectiveDocId = collection == 'cases'
      ? _caseDocIdForUser(uid, docId)
      : docId;

    final shouldEnrichForCreate = action == 'CREATE';
    final effectiveData = !shouldEnrichForCreate
        ? data
        : collection == 'cases'
            ? _withCaseParticipants(data)
        : (collection == 'tasks' || collection == 'assignments' || collection == 'chatGroups'
                ? _withParticipants(data)
          : collection == 'notices'
            ? _withNoticeParticipants(data)
                : data);

    await _db
        .collection(collection)
        .doc(effectiveDocId)
      .set(effectiveData, SetOptions(merge: true));
  }

  /// Delete any document (used by sync engine)
  Future<void> deleteDocument(String collection, String docId) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    if (collection == 'notices') {
      await deleteNoticeSecure(docId);
      return;
    }

    final effectiveDocId = collection == 'cases'
        ? _caseDocIdForUser(uid, docId)
        : docId;
    await _db.collection(collection).doc(effectiveDocId).delete();
  }
}