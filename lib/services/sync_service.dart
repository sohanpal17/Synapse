import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'hive_service.dart';
import 'firestore_service.dart';
import 'notification_service.dart';
import 'auth_service.dart';

const _uuid = Uuid();

/// Manages offline sync queue and auto-escalation
class SyncService {
  final FirestoreService _firestore = FirestoreService();
  static const Duration _staleTaskCreateRetention = Duration(hours: 24);
  static const Duration _maxEscalationDelay = Duration(hours: 24);

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

  dynamic _sanitizeForHive(dynamic value) {
    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    }
    if (value is Map) {
      return value.map((key, val) => MapEntry(key, _sanitizeForHive(val)));
    }
    if (value is List) {
      return value.map(_sanitizeForHive).toList();
    }
    return value;
  }

  Map<String, dynamic> _sanitizeMapForHive(Map<String, dynamic> data) {
    return Map<String, dynamic>.from(_sanitizeForHive(data) as Map);
  }

  bool _isPermanentSyncError(Object error) {
    if (error is FirebaseException) {
      return error.code == 'permission-denied' ||
          error.code == 'unauthenticated';
    }

    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('missing or insufficient permissions');
  }

  String _itemLabel(Map<String, dynamic> item) {
    final action = (item['action'] ?? 'UNKNOWN').toString();
    final collection = (item['collection'] ?? '').toString();
    final docId = (item['documentId'] ?? '').toString();
    return '$action $collection/$docId';
  }

  // ══════════ QUEUE AN OFFLINE ACTION ══════════

  /// Add any action to the sync queue (called when offline or as safety net)
  /// Set [skipImmediateSync] to true during batch operations (e.g. import)
  static Future<void> queueAction({
    required String action, // 'CREATE', 'UPDATE', 'DELETE'
    required String collection,
    required String documentId,
    required Map<String, dynamic> data,
    bool skipImmediateSync = false,
  }) async {
    final item = {
      'id': _uuid.v4(),
      'action': action,
      'collection': collection,
      'documentId': documentId,
      'data': data,
      'timestamp': DateTime.now().toIso8601String(),
      'retryCount': 0,
    };

    await HiveService.addToSyncQueue(item);

    // Try immediate sync if online, but do NOT abort if slow or offline
    // Fire-and-forget to prevent UI elements from freezing indefinitely
    if (!skipImmediateSync) {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity != ConnectivityResult.none) {
        SyncService()._processSingleItem(item).then((_) {
          HiveService.removeFromSyncQueue(item['id'] as String);
        }).catchError((e) {
          final syncService = SyncService();
          if (syncService._isPermanentSyncError(e)) {
            HiveService.removeFromSyncQueue(item['id'] as String);
            debugPrint(
              'Immediate sync permanently rejected (${syncService._itemLabel(item)}), dropped from queue: $e',
            );
            return;
          }
          debugPrint(
            'Immediate sync failed for ${syncService._itemLabel(item)}, queued for later: $e',
          );
        });
      }
    }
  }

  // ══════════ PROCESS SYNC QUEUE ══════════

  /// Process all pending sync actions (called by WorkManager or manually)
  Future<void> processQueue() async {
    final queue = HiveService.getSyncQueue();
    if (queue.isEmpty) return;

    final now = DateTime.now();
    for (final item in queue) {
      final isStaleTaskCreate =
          (item['collection'] ?? '') == 'tasks' &&
          (item['action'] ?? '') == 'CREATE';
      if (!isStaleTaskCreate) continue;
      final queuedAt = DateTime.tryParse((item['timestamp'] ?? '').toString());
      if (queuedAt != null && now.difference(queuedAt) > _staleTaskCreateRetention) {
        await HiveService.removeFromSyncQueue((item['id'] ?? '').toString());
      }
    }

    // Sort by timestamp (oldest first)
    queue.sort((a, b) => (a['timestamp'] ?? '').toString().compareTo(
        (b['timestamp'] ?? '').toString()));

    for (final item in queue) {
      try {
        await _processSingleItem(item);
        await HiveService.removeFromSyncQueue(item['id'] as String);
      } catch (e) {
        if (_isPermanentSyncError(e)) {
          await HiveService.removeFromSyncQueue(item['id'] as String);
          debugPrint(
            'Sync permanently rejected (${_itemLabel(item)}), dropped from queue: $e',
          );
          continue;
        }

        debugPrint('Sync error for ${_itemLabel(item)} (${item['id'] as String}): $e');
        final retryCount = (item['retryCount'] ?? 0) + 1;
        if (retryCount >= 5) {
          // Give up after 5 retries
          await HiveService.removeFromSyncQueue(item['id'] as String);
          debugPrint(
            'Sync item ${_itemLabel(item)} (${item['id'] as String}) dropped after 5 retries',
          );
        } else {
          item['retryCount'] = retryCount;
          await HiveService.addToSyncQueue(item);
        }
      }
    }
  }

  /// Process a single sync item
  Future<void> _processSingleItem(Map<String, dynamic> item) async {
    final collection = item['collection'] as String;
    final documentId = item['documentId'] as String;
    final data = Map<String, dynamic>.from(item['data'] ?? {});
    final action = item['action'] as String;

    switch (action) {
      case 'CREATE':
      case 'UPDATE':
        await _firestore.setDocument(
          collection,
          documentId,
          data,
          action: action,
        );
        break;
      case 'DELETE':
        await _firestore.deleteDocument(collection, documentId);
        break;
    }
  }

  // ══════════ FULL SYNC (Cloud → Hive) ══════════

  /// Download all data from Firestore into Hive (called on login/app start)
  Future<void> fullSync() async {
    try {
      final uid = AuthService().currentUser?.uid ?? '';
      if (uid.isEmpty) return;

      final db = FirebaseFirestore.instance;

      // Prevent stale cross-account data from lingering in local cache.
      await HiveService.clearBox(HiveService.casesBox);
      await HiveService.clearBox(HiveService.tasksBox);
      await HiveService.clearBox(HiveService.assignmentsBox);
      await HiveService.clearBox(HiveService.chatGroupsBox);
      await HiveService.clearBox(HiveService.remindersBox);

      // Run all collection queries concurrently to drastically reduce login time
      final futures = await Future.wait([
        db.collection('cases').where('participantIds', arrayContains: uid).get(),
        db.collection('tasks').where('participantIds', arrayContains: uid).get(),
        db.collection('tasks').where('assignedJuniorIds', arrayContains: uid).get(),
        db.collection('tasks').where('isPublic', isEqualTo: true).get(),
        db.collection('assignments').where('participantIds', arrayContains: uid).get(),
        db.collection('assignments').where('assignedToIds', arrayContains: uid).get(),
        db.collection('assignments').where('assignedToId', isEqualTo: uid).get(),
        db.collection('notices').where('participantIds', arrayContains: uid).get(),
        db.collection('notices').where('authorId', isEqualTo: uid).get(),
        db.collection('reminders').where('participantIds', arrayContains: uid).get(),
        db.collection('reminders').where('createdBy', isEqualTo: uid).get(),
        db.collection('chatGroups').where('memberIds', arrayContains: uid).get(),
      ]);

      for (final doc in futures[0].docs) {
        final data = _sanitizeMapForHive(doc.data());
        final cino = (data['cino'] as String? ?? '').trim();
        final key = cino.isNotEmpty ? cino : doc.id;
        await HiveService.put(HiveService.casesBox, key, data);
      }
      for (final doc in [...futures[1].docs, ...futures[2].docs, ...futures[3].docs]) {
        await HiveService.put(
          HiveService.tasksBox,
          doc.id,
          _sanitizeMapForHive(doc.data()),
        );
      }
      for (final doc in [...futures[4].docs, ...futures[5].docs, ...futures[6].docs]) {
        await HiveService.put(
          HiveService.assignmentsBox,
          doc.id,
          _sanitizeMapForHive(doc.data()),
        );
      }
      for (final doc in [...futures[7].docs, ...futures[8].docs]) {
        await HiveService.put(
          HiveService.noticesBox,
          doc.id,
          _sanitizeMapForHive(doc.data()),
        );
      }
      for (final doc in [...futures[9].docs, ...futures[10].docs]) {
        await HiveService.put(
          HiveService.remindersBox,
          doc.id,
          _sanitizeMapForHive(doc.data()),
        );
      }
      for (final doc in futures[11].docs) {
        await HiveService.put(
          HiveService.chatGroupsBox,
          doc.id,
          _sanitizeMapForHive(doc.data()),
        );
      }

      // Also process any pending uploads
      await processQueue();

      // Record sync time
      await HiveService.saveSetting(
          'lastFullSync', DateTime.now().toIso8601String());

      debugPrint('Full sync completed: ${futures[0].docs.length} cases');
    } catch (e) {
      debugPrint('Full sync error (working from cached data): $e');
    }
  }

  // ══════════ AUTO-ESCALATION ══════════

  /// Check all tasks and auto-escalate overdue ones
  /// Only escalates Tasks (not Assignments — per spec)
  Future<void> checkEscalations() async {
    final tasks = HiveService.getAll(HiveService.tasksBox);
    final now = DateTime.now();
    bool escalatedAny = false;

    for (final task in tasks) {
      // Only escalate 'task' type, not 'assignment'
      if (task['type'] != 'task') continue;
      if (_normalizeWorkStatus(task['status']) == 'completed') continue;
      if (task['isEscalated'] == true) continue;
      if (task['autoEscalate'] != true) continue;

      final deadline = DateTime.tryParse((task['deadline'] ?? '').toString());
      if (deadline != null && now.isAfter(deadline)) {
        // Ignore very old overdue tasks to prevent stale escalation notification spam.
        if (now.difference(deadline) > _maxEscalationDelay) {
          task['autoEscalate'] = false;
          task['updatedAt'] = now.toIso8601String();
          await HiveService.put(HiveService.tasksBox, task['id'], task);
          await queueAction(
            action: 'UPDATE',
            collection: 'tasks',
            documentId: task['id'],
            data: {
              'autoEscalate': false,
              'updatedAt': task['updatedAt'],
            },
          );
          continue;
        }

        // ESCALATE
        task['isEscalated'] = true;
        task['isPublic'] = true;
        task['escalatedAt'] = now.toIso8601String();
        task['status'] = 'overdue';
        task['updatedAt'] = now.toIso8601String();
        escalatedAny = true;

        // Update local
        await HiveService.put(HiveService.tasksBox, task['id'], task);

        // Queue for cloud sync
        await queueAction(
          action: 'UPDATE',
          collection: 'tasks',
          documentId: task['id'],
          data: task,
        );

        debugPrint('Escalated task: ${task['title']}');
      }
    }

    if (escalatedAny) {
      // Force queue processing once so all users see escalated visibility quickly.
      await processQueue();
    }
  }
}