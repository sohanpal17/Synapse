import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/case_model.dart';
import 'sync_service.dart';

/// Handles all Firestore read/write operations
class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

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
    participants.addAll(
      List<String>.from(map['clientIds'] ?? const []),
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
      _db.collection('tasks').where('isPublic', isEqualTo: true).get(),
    ]);

    return _mergeByDocumentId(
      [...snapshots[0].docs, ...snapshots[1].docs],
      snapshots[2].docs,
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
    final publicStream = _db
        .collection('tasks')
        .where('isPublic', isEqualTo: true)
        .snapshots();

    final controller = StreamController<List<Map<String, dynamic>>>();
    List<QueryDocumentSnapshot<Map<String, dynamic>>> participantDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> assignedDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> publicDocs = const [];

    void emitMerged() {
      controller.add(_mergeByDocumentId(
        [...participantDocs, ...assignedDocs],
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
    final subC = publicStream.listen(
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
    };

    return controller.stream;
  }

  /// Delete a task
  Future<void> deleteTask(String taskId) async {
    await _db.collection('tasks').doc(taskId).delete();
  }

  // ══════════════════════════════════════
  //             ASSIGNMENTS
  // ══════════════════════════════════════

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

  // ══════════════════════════════════════
  //              NOTICES
  // ══════════════════════════════════════

  /// Create a notice
  Future<void> createNotice(Map<String, dynamic> notice) async {
    await _db.collection('notices').doc(notice['id']).set(notice);
  }

  /// Get all notices for the firm
  Future<List<Map<String, dynamic>>> getNotices() async {
    final snapshot = await _db
        .collection('notices')
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs.map((doc) => doc.data()).toList();
  }

  /// Real-time stream of notices
  Stream<List<Map<String, dynamic>>> watchNotices() {
    return _db
        .collection('notices')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  /// Delete a notice
  Future<void> deleteNotice(String noticeId) async {
    await _db.collection('notices').doc(noticeId).delete();
  }

  // ══════════════════════════════════════
  //             CHAT GROUPS
  // ══════════════════════════════════════

  /// Create a chat group
  Future<void> createChatGroup(Map<String, dynamic> group) async {
    await _db.collection('chatGroups').doc(group['id']).set(group);
  }

  /// Get all chat groups for the firm
  Stream<List<Map<String, dynamic>>> watchChatGroups() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value(const []);
    return _db
        .collection('chatGroups')
      .where('memberIds', arrayContains: uid)
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
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

  // ══════════════════════════════════════
  //              MESSAGES
  // ══════════════════════════════════════

  /// Send a message to a chat group
  Future<void> sendMessage(Map<String, dynamic> message) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    final groupId = message['chatGroupId'];
    final groupRef = _db.collection('chatGroups').doc(groupId);
    final groupDoc = await groupRef.get();
    if (!groupDoc.exists) return;

    final memberIds = List<String>.from(groupDoc.data()?['memberIds'] ?? const []);
    if (!memberIds.contains(uid)) {
      throw StateError('You are not allowed to send messages to this chat.');
    }

    // Save message in subcollection
    await groupRef
        .collection('messages')
        .doc(message['id'])
        .set(message);

    // Update the group's last message preview
    await groupRef.update({
      'lastMessage': message['content'],
      'lastMessageTime': message['timestamp'],
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
    await _db.collection('sos_alerts').doc(sos['id']).set(sos);
  }

  /// Get SOS alerts for a user (recipient)
  Stream<List<Map<String, dynamic>>> watchSOSAlerts(String userId) {
    return _db
        .collection('sos_alerts')
        .where('recipientIds', arrayContains: userId)
        .limit(20)
        .snapshots()
        .map((s) {
          final items = s.docs.map((d) => d.data()).toList();
          DateTime parseTs(Map<String, dynamic> m) {
            final raw = (m['timestamp'] ?? '').toString();
            return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
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
    await _db
        .collection('reminders')
        .doc(reminder['id'])
        .set(reminder, SetOptions(merge: true));
  }

  /// Get reminders for the firm
  Future<List<Map<String, dynamic>>> getReminders() async {
    final snapshot = await _db
        .collection('reminders')
        .get();

    return snapshot.docs.map((doc) => doc.data()).toList();
  }

  /// Real-time stream of reminders
  Stream<List<Map<String, dynamic>>> watchReminders() {
    return _db
        .collection('reminders')
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  // ══════════════════════════════════════
  //         GENERIC OPERATIONS
  //   (Used by SyncService for queue)
  // ══════════════════════════════════════

  /// Set any document (used by sync engine)
  Future<void> setDocument(
      String collection, String docId, Map<String, dynamic> data) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    final effectiveDocId = collection == 'cases'
      ? _caseDocIdForUser(uid, docId)
      : docId;

    final effectiveData = collection == 'cases'
      ? _withCaseParticipants(data)
      : (collection == 'tasks' || collection == 'assignments' || collection == 'chatGroups'
        ? _withParticipants(data)
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

    final effectiveDocId = collection == 'cases'
        ? _caseDocIdForUser(uid, docId)
        : docId;
    await _db.collection(collection).doc(effectiveDocId).delete();
  }
}