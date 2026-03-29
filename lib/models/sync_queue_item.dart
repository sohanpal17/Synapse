import '../utils/date_formatter.dart';

/// Represents a pending offline action that needs to be synced to Firestore
class SyncQueueItem {
  final String id;
  final String action; // 'CREATE', 'UPDATE', 'DELETE'
  final String collection; // Firestore collection name
  final String documentId;
  final Map<String, dynamic> data;
  final DateTime timestamp;
  int retryCount;

  SyncQueueItem({
    required this.id,
    required this.action,
    required this.collection,
    required this.documentId,
    required this.data,
    DateTime? timestamp,
    this.retryCount = 0,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'action': action,
        'collection': collection,
        'documentId': documentId,
        'data': data,
        'timestamp': timestamp.toIso8601String(),
        'retryCount': retryCount,
      };

  factory SyncQueueItem.fromMap(Map<String, dynamic> map) => SyncQueueItem(
        id: map['id'] ?? '',
        action: map['action'] ?? 'CREATE',
        collection: map['collection'] ?? '',
        documentId: map['documentId'] ?? '',
        data: Map<String, dynamic>.from(map['data'] ?? {}),
        timestamp: DateFormatter.parseDate(map['timestamp']),
        retryCount: map['retryCount'] ?? 0,
      );
}