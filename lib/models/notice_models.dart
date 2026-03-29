import 'package:flutter/material.dart';
import '../utils/date_formatter.dart';

enum NoticePriority { normal, important }

extension NoticePriorityExtension on NoticePriority {
  String get displayName {
    switch (this) {
      case NoticePriority.normal: return 'Normal';
      case NoticePriority.important: return 'Important';
    }
  }

  Color get color {
    switch (this) {
      case NoticePriority.normal: return const Color(0xFF4CAF50);
      case NoticePriority.important: return const Color(0xFFE53935);
    }
  }

  IconData get icon {
    switch (this) {
      case NoticePriority.normal: return Icons.info_outline;
      case NoticePriority.important: return Icons.priority_high;
    }
  }
}

class Notice {
  final String id;
  final String title;
  final String content;
  final String authorId;
  final String authorName;
  final String authorRole;
  final DateTime createdAt;
  final NoticePriority priority;
  final bool isPinned;

  Notice({
    required this.id,
    required this.title,
    required this.content,
    required this.authorId,
    required this.authorName,
    required this.authorRole,
    required this.createdAt,
    this.priority = NoticePriority.normal,
    this.isPinned = false,
  });

  String getTimeAgo() {
    final duration = DateTime.now().difference(createdAt);
    if (duration.inMinutes < 1) return 'Just now';
    if (duration.inMinutes < 60) return '${duration.inMinutes}m ago';
    if (duration.inHours < 24) return '${duration.inHours}h ago';
    if (duration.inDays < 7) return '${duration.inDays}d ago';
    if (duration.inDays < 30) return '${(duration.inDays / 7).floor()}w ago';
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }

  String getFormattedDate() {
    return '${createdAt.day}/${createdAt.month}/${createdAt.year} at '
        '${createdAt.hour}:${createdAt.minute.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'authorId': authorId,
        'authorName': authorName,
        'authorRole': authorRole,
        'createdAt': createdAt.toIso8601String(),
        'priority': priority.name,
        'isPinned': isPinned,
      };

  factory Notice.fromMap(Map<String, dynamic> map) => Notice(
        id: map['id'] ?? '',
        title: map['title'] ?? '',
        content: map['content'] ?? '',
        authorId: map['authorId'] ?? '',
        authorName: map['authorName'] ?? '',
        authorRole: map['authorRole'] ?? '',
        createdAt: DateFormatter.parseDate(map['createdAt']),
        priority: NoticePriority.values.firstWhere(
            (e) => e.name == map['priority'],
            orElse: () => NoticePriority.normal),
        isPinned: map['isPinned'] ?? false,
      );
}