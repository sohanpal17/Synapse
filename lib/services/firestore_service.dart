import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/case_model.dart';
import 'sync_service.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  // ================= CASES =================

  Future<void> upsertCase(CaseModel c) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    await _db.collection('cases').doc(c.cino).set(c.toMap(), SetOptions(merge: true));
  }

  Stream<List<CaseModel>> watchCases() {
    final uid = _currentUid;
    if (uid.isEmpty) return Stream.value([]);

    return _db
        .collection('cases')
        .where('participantIds', arrayContains: uid)
        .snapshots()
        .map((s) => s.docs.map((d) => CaseModel.fromMap(d.data())).toList());
  }

  Future<void> deleteCase(String cino) async {
    await _db.collection('cases').doc(cino).delete();
  }

  // ================= CHAT GROUPS =================

  Future<void> createChatGroup(Map<String, dynamic> group) async {
    await _db.collection('chatGroups').doc(group['id']).set(group);
  }

  // 🔥 FIXED: user-scoped query
  Stream<List<Map<String, dynamic>>> watchChatGroups(String uid) {
    return _db
        .collection('chatGroups')
        .where('memberIds', arrayContains: uid)
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  Future<void> deleteChatGroup(String groupId) async {
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

  // ================= MESSAGES =================

  Future<void> sendMessage(Map<String, dynamic> message) async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    final groupId = message['chatGroupId'];
    final groupRef = _db.collection('chatGroups').doc(groupId);

    final groupDoc = await groupRef.get();
    if (!groupDoc.exists) return;

    final memberIds = List<String>.from(groupDoc.data()?['memberIds'] ?? []);
    if (!memberIds.contains(uid)) {
      throw Exception("User not in chat");
    }

    await groupRef
        .collection('messages')
        .doc(message['id'])
        .set(message);

    await groupRef.update({
      'lastMessage': message['content'],
      'lastMessageTime': message['timestamp'],
    });
  }

  Stream<List<Map<String, dynamic>>> watchMessages(String chatGroupId) {
    return _db
        .collection('chatGroups')
        .doc(chatGroupId)
        .collection('messages')
        .orderBy('timestamp')
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  // ================= SOS =================

  Future<void> sendSOS(Map<String, dynamic> sos) async {
    await _db.collection('sos_alerts').doc(sos['id']).set(sos);
  }

  Stream<List<Map<String, dynamic>>> watchSOSAlerts(String uid) {
    return _db
        .collection('sos_alerts')
        .where('recipientIds', arrayContains: uid)
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  // ================= REMINDERS =================

  Future<void> upsertReminder(Map<String, dynamic> reminder) async {
    await _db.collection('reminders').doc(reminder['id']).set(reminder);
  }

  Stream<List<Map<String, dynamic>>> watchReminders() {
    return _db
        .collection('reminders')
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  // ================= GENERIC =================

  Future<void> setDocument(String collection, String docId, Map<String, dynamic> data) async {
    await _db.collection(collection).doc(docId).set(data, SetOptions(merge: true));
  }

  Future<void> deleteDocument(String collection, String docId) async {
    await _db.collection(collection).doc(docId).delete();
  }
  // ================= EXTRA REQUIRED METHODS =================

Stream<List<Map<String, dynamic>>> watchCasesRaw() {
  final uid = _currentUid;
  if (uid.isEmpty) return Stream.value([]);

  return _db
      .collection('cases')
      .where('participantIds', arrayContains: uid)
      .snapshots()
      .map((s) => s.docs.map((d) => d.data()).toList());
}

Stream<List<Map<String, dynamic>>> watchTasks() {
  final uid = _currentUid;
  if (uid.isEmpty) return Stream.value([]);

  return _db
      .collection('tasks')
      .where('participantIds', arrayContains: uid)
      .snapshots()
      .map((s) => s.docs.map((d) => d.data()).toList());
}

Stream<List<Map<String, dynamic>>> watchAssignments() {
  final uid = _currentUid;
  if (uid.isEmpty) return Stream.value([]);

  return _db
      .collection('assignments')
      .where('participantIds', arrayContains: uid)
      .snapshots()
      .map((s) => s.docs.map((d) => d.data()).toList());
}

Stream<List<Map<String, dynamic>>> watchNotices() {
  return _db
      .collection('notices')
      .snapshots()
      .map((s) => s.docs.map((d) => d.data()).toList());
}

Future<void> upsertCases(List<CaseModel> cases, {String? source}) async {
  for (final c in cases) {
    await _db.collection('cases').doc(c.cino).set(c.toMap());
  }
}
}