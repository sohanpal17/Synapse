import 'package:flutter/material.dart';
import 'reminder_models.dart';

/// Mock data for reminders/calendar features
class ReminderMockData {
  static List<Reminder> getRemindersForUser(String userId) {
    return _reminders
        .where((r) => r.isVisibleToUser(userId))
        .toList()
      ..sort((a, b) => a.dueDateTime.compareTo(b.dueDateTime));
  }

  static List<Reminder> getCompletedReminders(String userId) {
    return getRemindersForUser(userId).where((r) => r.isCompleted).toList();
  }

  static List<Reminder> getIncompleteReminders(String userId) {
    return getRemindersForUser(userId).where((r) => !r.isCompleted).toList();
  }

  static bool hasRemindersOnDate(DateTime date, String userId) {
    final reminders = getRemindersForUser(userId);
    return reminders.any((r) =>
        r.dueDateTime.year == date.year &&
        r.dueDateTime.month == date.month &&
        r.dueDateTime.day == date.day);
  }

  static Color getDateUrgencyColor(DateTime date, String userId) {
    final reminders = getRemindersForUser(userId).where((r) =>
        r.dueDateTime.year == date.year &&
        r.dueDateTime.month == date.month &&
        r.dueDateTime.day == date.day);

    if (reminders.isEmpty) return Colors.grey;

    // Return the most urgent color (red > yellow > green)
    Color mostUrgent = const Color(0xFF4CAF50);
    for (final r in reminders) {
      final c = r.getUrgencyColor();
      if (c == const Color(0xFFE53935)) return c; // Red is most urgent
      if (c == const Color(0xFFFF9800)) mostUrgent = c;
    }
    return mostUrgent;
  }

  // ── Mock Data ──
  static final List<Reminder> _reminders = [
    Reminder(
      id: 'r1',
      title: 'File reply in Singh vs State',
      description: 'Submit counter-affidavit before the next hearing date.',
      dueDateTime: DateTime.now().add(const Duration(hours: 18)),
      createdBy: 's1',
      createdByName: 'Adv. Rajesh Sharma',
      createdAt: DateTime.now().subtract(const Duration(days: 3)),
      visibility: ReminderVisibility.everyone,
    ),
    Reminder(
      id: 'r2',
      title: 'Prepare arguments for bail application',
      description: 'Research on recent bail precedents for narcotic cases.',
      dueDateTime: DateTime.now().add(const Duration(days: 2)),
      createdBy: 's1',
      createdByName: 'Adv. Rajesh Sharma',
      createdAt: DateTime.now().subtract(const Duration(days: 1)),
    ),
    Reminder(
      id: 'r3',
      title: 'Client meeting - Mehta Property Dispute',
      description: 'Discuss settlement options with client.',
      dueDateTime: DateTime.now().add(const Duration(days: 4)),
      createdBy: 's1',
      createdByName: 'Adv. Rajesh Sharma',
      createdAt: DateTime.now().subtract(const Duration(days: 2)),
      visibility: ReminderVisibility.specificUsers,
      sharedWithUserIds: ['s2', 'j1'],
    ),
    Reminder(
      id: 'r4',
      title: 'Submit court fee challan',
      description: 'Payment for revision petition filing.',
      dueDateTime: DateTime.now().subtract(const Duration(hours: 5)),
      createdBy: 's1',
      createdByName: 'Adv. Rajesh Sharma',
      createdAt: DateTime.now().subtract(const Duration(days: 5)),
    ),
    Reminder(
      id: 'r5',
      title: 'Review intern research notes',
      description: 'Check CPC amendments research prepared by Neha.',
      dueDateTime: DateTime.now().add(const Duration(days: 7)),
      isCompleted: true,
      createdBy: 's1',
      createdByName: 'Adv. Rajesh Sharma',
      createdAt: DateTime.now().subtract(const Duration(days: 10)),
      completedAt: DateTime.now().subtract(const Duration(days: 1)),
    ),
  ];
}
