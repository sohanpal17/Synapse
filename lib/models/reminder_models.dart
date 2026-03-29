import 'package:flutter/material.dart';
import '../utils/date_formatter.dart';

// ==================== REMINDER VISIBILITY ====================
enum ReminderVisibility { private, lawyers, interns, specificUsers, everyone }

extension ReminderVisibilityExtension on ReminderVisibility {
  String get displayName {
    switch (this) {
      case ReminderVisibility.private: return 'Private (Only Me)';
      case ReminderVisibility.lawyers: return 'Lawyers';
      case ReminderVisibility.interns: return 'Interns';
      case ReminderVisibility.specificUsers: return 'Specific Users';
      case ReminderVisibility.everyone: return 'Everyone';
    }
  }

  IconData get icon {
    switch (this) {
      case ReminderVisibility.private: return Icons.lock;
      case ReminderVisibility.lawyers: return Icons.gavel;
      case ReminderVisibility.interns: return Icons.school;
      case ReminderVisibility.specificUsers: return Icons.people;
      case ReminderVisibility.everyone: return Icons.public;
    }
  }
}

// ==================== REMINDER ====================
class Reminder {
  final String id;
  final String title;
  final String description;
  final DateTime dueDateTime;
  final bool isCompleted;
  final ReminderVisibility visibility;
  final List<String> sharedWithUserIds;
  final String createdBy;
  final String createdByName;
  final DateTime createdAt;
  final DateTime? completedAt;

  Reminder({
    required this.id,
    required this.title,
    required this.description,
    required this.dueDateTime,
    this.isCompleted = false,
    this.visibility = ReminderVisibility.private,
    this.sharedWithUserIds = const [],
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    this.completedAt,
  });

  Reminder copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? dueDateTime,
    bool? isCompleted,
    ReminderVisibility? visibility,
    List<String>? sharedWithUserIds,
    String? createdBy,
    String? createdByName,
    DateTime? createdAt,
    DateTime? completedAt,
  }) {
    return Reminder(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      dueDateTime: dueDateTime ?? this.dueDateTime,
      isCompleted: isCompleted ?? this.isCompleted,
      visibility: visibility ?? this.visibility,
      sharedWithUserIds: sharedWithUserIds ?? this.sharedWithUserIds,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  bool isOverdue() {
    if (isCompleted) return false;
    return DateTime.now().isAfter(dueDateTime);
  }

  Color getUrgencyColor() {
    if (isCompleted) return Colors.grey;
    if (isOverdue()) return const Color(0xFFE53935);
    final hoursRemaining = dueDateTime.difference(DateTime.now()).inHours;
    if (hoursRemaining < 24) return const Color(0xFFE53935);
    if (hoursRemaining < 72) return const Color(0xFFFF9800);
    return const Color(0xFF4CAF50);
  }

  String getUrgencyLabel() {
    if (isCompleted) return 'Completed';
    if (isOverdue()) return 'Overdue';
    final hoursRemaining = dueDateTime.difference(DateTime.now()).inHours;
    if (hoursRemaining < 24) return 'Due soon';
    if (hoursRemaining < 72) return 'Approaching';
    return 'Upcoming';
  }

  String getTimeRemaining() {
    if (isCompleted) return 'Completed';
    if (isOverdue()) {
      final d = DateTime.now().difference(dueDateTime);
      if (d.inDays > 0) return '${d.inDays}d overdue';
      if (d.inHours > 0) return '${d.inHours}h overdue';
      return '${d.inMinutes}m overdue';
    }
    final d = dueDateTime.difference(DateTime.now());
    if (d.inDays > 0) return '${d.inDays}d remaining';
    if (d.inHours > 0) return '${d.inHours}h remaining';
    return '${d.inMinutes}m remaining';
  }

  String getFormattedDueDate() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final dueDate = DateTime(dueDateTime.year, dueDateTime.month, dueDateTime.day);

    String dateStr;
    if (dueDate == today) {
      dateStr = 'Today';
    } else if (dueDate == tomorrow) {
      dateStr = 'Tomorrow';
    } else {
      dateStr = '${dueDateTime.day}/${dueDateTime.month}/${dueDateTime.year}';
    }

    final hour = dueDateTime.hour > 12
        ? dueDateTime.hour - 12
        : (dueDateTime.hour == 0 ? 12 : dueDateTime.hour);
    final period = dueDateTime.hour >= 12 ? 'PM' : 'AM';
    final minute = dueDateTime.minute.toString().padLeft(2, '0');
    return '$dateStr at $hour:$minute $period';
  }

  bool isVisibleToUser(String userId, {String userRole = ''}) {
    if (createdBy == userId) return true;
    switch (visibility) {
      case ReminderVisibility.private: return false;
      case ReminderVisibility.lawyers: return userRole.toLowerCase() == 'lawyer';
      case ReminderVisibility.interns: return userRole.toLowerCase() == 'intern';
      case ReminderVisibility.specificUsers: return sharedWithUserIds.contains(userId);
      case ReminderVisibility.everyone: return true;
    }
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'description': description,
        'dueDateTime': dueDateTime.toIso8601String(),
        'isCompleted': isCompleted,
        'visibility': visibility.name,
        'sharedWithUserIds': sharedWithUserIds,
        'createdBy': createdBy,
        'createdByName': createdByName,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
      };

  factory Reminder.fromMap(Map<String, dynamic> map) => Reminder(
        id: map['id'] ?? '',
        title: map['title'] ?? '',
        description: map['description'] ?? '',
        dueDateTime: DateFormatter.parseDate(map['dueDateTime']),
        isCompleted: map['isCompleted'] ?? false,
        visibility: ReminderVisibility.values.firstWhere(
            (e) => e.name == map['visibility'],
            orElse: () => ReminderVisibility.private),
        sharedWithUserIds: List<String>.from(map['sharedWithUserIds'] ?? []),
        createdBy: map['createdBy'] ?? '',
        createdByName: map['createdByName'] ?? '',
        createdAt: DateFormatter.parseDate(map['createdAt']),
        completedAt: DateFormatter.parseDateNullable(map['completedAt']),
      );
}