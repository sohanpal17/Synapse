import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/case_model.dart';
import 'hive_service.dart';
import 'sync_service.dart';
import 'firestore_service.dart';

/// Result summary of an eCourts import operation
class EcourtsImportResult {
  final int total;
  final int newCases;
  final int updated;
  final int errors;
  final List<String> errorMessages;

  EcourtsImportResult({
    required this.total,
    required this.newCases,
    required this.updated,
    this.errors = 0,
    this.errorMessages = const [],
  });
}

/// Handles parsing eCourts export files and importing into Synapse
class EcourtsImportService {
  /// Parse from raw bytes (works on ALL platforms including web)
  static Future<List<CaseModel>> parseBytes(Uint8List bytes) async {
    final params = {
      'bytes': bytes,
    };

    // compute() uses isolates which can hang on web — run directly
    if (kIsWeb) {
      return _parseInIsolate(params);
    }
    return compute(_parseInIsolate, params);
  }

  /// The actual parsing logic — runs in isolate (background thread)
  static List<CaseModel> _parseInIsolate(Map<String, dynamic> params) {
    final bytes = params['bytes'] as List<int>;
    final rawString = utf8.decode(bytes, allowMalformed: true).trim();
    final List<Map<String, dynamic>> rawEntries = [];

    // ── Strategy 1: Standard JSON array ──
    try {
      final decoded = jsonDecode(rawString);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            rawEntries.add(Map<String, dynamic>.from(item));
          } else if (item is String) {
            // Double-encoded: array of JSON strings
            try {
              final parsed = jsonDecode(item);
              if (parsed is Map) {
                rawEntries.add(Map<String, dynamic>.from(parsed));
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // Strategy 1 failed, try alternatives
    }

    // ── Strategy 2: Brace-matching fallback ──
    if (rawEntries.isEmpty) {
      _braceFallback(rawString, rawEntries);
    }

    // ── Strategy 3: Line-by-line ──
    if (rawEntries.isEmpty) {
      for (final line in rawString.split('\n')) {
        final trimmed =
            line.trim().replaceAll(RegExp(r'^["\[,]+|["\],]+$'), '');
        if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
          try {
            rawEntries.add(Map<String, dynamic>.from(jsonDecode(trimmed)));
          } catch (_) {}
        }
      }
    }

    // Filter only entries with CINO (valid case records)
    return rawEntries
        .where((e) => e.containsKey('cino') && e['cino'] != null)
        .map((e) {
      try {
        return CaseModel.fromEcourtsJson(e);
      } catch (_) {
        return null;
      }
    })
        .whereType<CaseModel>()
        .toList();
  }

  /// Brace-matching JSON parser for malformed data
  static void _braceFallback(
      String raw, List<Map<String, dynamic>> entries) {
    int depth = 0;
    int start = -1;

    for (int i = 0; i < raw.length; i++) {
      if (raw[i] == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (raw[i] == '}') {
        depth--;
        if (depth == 0 && start >= 0) {
          try {
            final jsonStr = raw.substring(start, i + 1);
            final parsed = jsonDecode(jsonStr);
            if (parsed is Map) {
              entries.add(Map<String, dynamic>.from(parsed));
            }
          } catch (_) {}
          start = -1;
        }
      }
    }
  }

  /// Import parsed cases into Hive + queue for Firestore sync
  /// Uses UPSERT logic: new cases are added, existing cases are updated
  static Future<EcourtsImportResult> importCases(List<CaseModel> cases) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      return EcourtsImportResult(
        total: cases.length,
        newCases: 0,
        updated: 0,
        errors: cases.length,
        errorMessages: const ['Please login before importing cases.'],
      );
    }

    int newCount = 0;
    int updateCount = 0;
    int errorCount = 0;
    final List<String> errors = [];
    final List<CaseModel> mergedCases = [];

    for (final c in cases) {
      try {
        final existing = HiveService.get(HiveService.casesBox, c.cino);
        final isNew = existing == null;

        if (isNew) {
          newCount++;
        } else {
          updateCount++;
        }

        // Write to Hive (instant, offline) with explicit source tag.
        final caseMap = c.toMap();
        caseMap['source'] = 'ecourts';
        caseMap['ownerUid'] = uid;

        // Preserve user-managed data when re-importing an existing case.
        if (existing != null) {
          caseMap['customDocuments'] = existing['customDocuments'] ?? caseMap['customDocuments'];
          caseMap['assignedLawyerIds'] = existing['assignedLawyerIds'] ?? caseMap['assignedLawyerIds'];
          caseMap['assignedInternIds'] = existing['assignedInternIds'] ?? caseMap['assignedInternIds'];
          caseMap['clientIds'] = existing['clientIds'] ?? caseMap['clientIds'];
          caseMap['participantIds'] = existing['participantIds'] ?? caseMap['participantIds'];
          caseMap['createdAt'] = existing['createdAt'] ?? caseMap['createdAt'];
        }

        await HiveService.put(HiveService.casesBox, c.cino, caseMap);
        mergedCases.add(CaseModel.fromMap(caseMap));
      } catch (e) {
        errorCount++;
        errors.add('${c.cino}: $e');
        continue;
      }

      // Calendar entry is best-effort and should not fail the case import.
      try {
        if (c.nextHearingDate != null && !c.isClosed) {
          final dateKey = _formatDateKey(c.nextHearingDate!);
          await HiveService.addEventToDate(dateKey, {
            'caseId': c.cino,
            'caseName': c.title,
            'courtRoom': c.courtRoom,
            'courtComplex': c.courtComplex,
            'stage': c.currentStage,
            'type': 'hearing',
          });
        }
      } catch (e) {
        debugPrint('Calendar sync skipped for ${c.cino}: $e');
      }
    }

    // Persist to Firestore before returning so imports are durable on web.
    try {
      await FirestoreService().upsertCases(mergedCases, source: 'ecourts');
    } catch (e) {
      errorCount++;
      errors.add('Cloud sync failed: $e');
      debugPrint('Batch case sync failed: $e');
    }

    return EcourtsImportResult(
      total: cases.length,
      newCases: newCount,
      updated: updateCount,
      errors: errorCount,
      errorMessages: errors,
    );
  }

  /// Deletes only eCourts-imported cases for current user.
  static Future<int> clearImportedCases() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return 0;

    final allCasesByKey = HiveService.getAllAsMap(HiveService.casesBox);
    int processedCount = 0;
    int queuedFallbackCount = 0;

    // Build a stable target list first to avoid mutation issues while processing.
    final targets = <MapEntry<String, Map<String, dynamic>>>[];
    for (final entry in allCasesByKey.entries) {
      final key = entry.key.trim();
      final c = entry.value;
      final ownerUid = (c['ownerUid'] as String? ?? '').trim();
      if (ownerUid.isNotEmpty && ownerUid != uid) continue;

      final source = (c['source'] as String? ?? '').trim().toLowerCase();
      final importSource = (c['importSource'] as String? ?? '').trim().toLowerCase();
      final importedFrom = (c['importedFrom'] as String? ?? '').trim().toLowerCase();
      final isImported = source == 'ecourts' || importSource == 'ecourts' || importedFrom == 'ecourts';
      if (!isImported) continue;

      final cino = (c['cino'] as String? ?? '').trim();
      final importId = cino.isNotEmpty ? cino : key;

      targets.add(MapEntry(key, {
        'importId': importId,
        'case': Map<String, dynamic>.from(c),
      }));
    }

    for (final t in targets) {
      final localKey = t.key;
      final importId = (t.value['importId'] as String? ?? '').trim();
      // Always remove locally first so imported cases disappear immediately.
      await HiveService.delete(HiveService.casesBox, localKey);

      // Try immediate cloud delete to prevent stale data from being pulled back by listeners.
      try {
        await FirestoreService().deleteDocument('cases', importId);
      } catch (_) {
        queuedFallbackCount++;
        await SyncService.queueAction(
          action: 'DELETE',
          collection: 'cases',
          documentId: importId,
          data: {},
          skipImmediateSync: true,
        );
      }

      processedCount++;
    }

    if (queuedFallbackCount > 0) {
      // Process queued deletes once after all batch actions are enqueued.
      await SyncService().processQueue();
    }

    return processedCount;
  }

  /// Format DateTime to calendar date key: "2024-12-15"
  static String _formatDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}