import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';

/// Central offline storage manager using Hive
/// All data is written here FIRST (offline-first pattern)
/// Then synced to Firestore when online
class HiveService {
  // ── Box Names ──
  static const String userBox = 'user_box';
  static const String casesBox = 'cases_box';
  static const String tasksBox = 'tasks_box';
  static const String assignmentsBox = 'assignments_box';
  static const String calendarBox = 'calendar_box';
  static const String remindersBox = 'reminders_box';
  static const String chatGroupsBox = 'chat_groups_box';
  static const String messagesBox = 'messages_box';
  static const String noticesBox = 'notices_box';
  static const String syncQueueBox = 'sync_queue_box';
  static const String sosBox = 'sos_box';
  static const String settingsBox = 'settings_box';

  /// Initialize all Hive boxes at app startup
  static Future<void> init() async {
    await _openBox(userBox);
    await _openBox(casesBox);
    await _openBox(tasksBox);
    await _openBox(assignmentsBox);
    await _openBox(calendarBox);
    await _openBox(remindersBox);
    await _openBox(chatGroupsBox);
    await _openBox(messagesBox);
    await _openBox(noticesBox);
    await _openBox(syncQueueBox);
    await _openBox(sosBox);

    // Settings box is not Map<dynamic,dynamic>, it stores primitives
    if (!Hive.isBoxOpen(settingsBox)) {
      await Hive.openBox(settingsBox);
    }
  }

  /// Safely open a box (prevents double-open errors)
  static Future<void> _openBox(String name) async {
    if (!Hive.isBoxOpen(name)) {
      await Hive.openBox<Map>(name);
    }
  }

  // ══════════ GENERIC CRUD ══════════

  /// Get the typed box reference
  static Box<Map> _box(String name) => Hive.box<Map>(name);

  /// Save a record
  static Future<void> put(
      String boxName, String key, Map<String, dynamic> value) async {
    await _box(boxName).put(key, value);
  }

  /// Get a single record by key
  static Map<String, dynamic>? get(String boxName, String key) {
    final raw = _box(boxName).get(key);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  /// Get all records from a box
  static List<Map<String, dynamic>> getAll(String boxName) {
    return _box(boxName)
        .values
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Get all records as a map (key → value)
  static Map<String, Map<String, dynamic>> getAllAsMap(String boxName) {
    final box = _box(boxName);
    final Map<String, Map<String, dynamic>> result = {};
    for (final key in box.keys) {
      final value = box.get(key);
      if (value != null) {
        result[key.toString()] = Map<String, dynamic>.from(value);
      }
    }
    return result;
  }

  /// Delete a single record
  static Future<void> delete(String boxName, String key) async {
    await _box(boxName).delete(key);
  }

  /// Clear all records in a box safely
  static Future<void> clearBox(String boxName) async {
    try {
      if (Hive.isBoxOpen(boxName)) {
        await _box(boxName).clear();
      }
    } catch (e) {
      debugPrint('Error clearing Hive box $boxName: $e');
    }
  }

  /// Check if a key exists
  static bool containsKey(String boxName, String key) {
    return _box(boxName).containsKey(key);
  }

  /// Get count of records in a box
  static int count(String boxName) {
    return _box(boxName).length;
  }

  // ══════════ SETTINGS (Simple Key-Value) ══════════

  static Box get _settingsBox => Hive.box(settingsBox);

  static Future<void> saveSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  static dynamic getSetting(String key, {dynamic defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue);
  }

  static Future<void> deleteSetting(String key) async {
    await _settingsBox.delete(key);
  }

  // ══════════ SYNC QUEUE ══════════

  /// Add an action to the offline sync queue
  static Future<void> addToSyncQueue(Map<String, dynamic> item) async {
    await _box(syncQueueBox).put(item['id'], item);
  }

  /// Get all pending sync actions
  static List<Map<String, dynamic>> getSyncQueue() {
    return getAll(syncQueueBox);
  }

  /// Remove a completed sync action
  static Future<void> removeFromSyncQueue(String id) async {
    await _box(syncQueueBox).delete(id);
  }

  /// Check if there are pending sync actions
  static bool hasPendingSyncs() {
    return _box(syncQueueBox).isNotEmpty;
  }

  // ══════════ CALENDAR HELPERS ══════════

  /// Get events for a specific date
  /// Date key format: "2024-12-15"
  static List<Map<String, dynamic>> getEventsForDate(String dateKey) {
    final data = get(calendarBox, dateKey);
    if (data == null) return [];
    return _normalizeEventList(data['events']);
  }

  /// Check if a date has events
  static bool hasEventsOnDate(String dateKey) {
    return containsKey(calendarBox, dateKey) &&
        getEventsForDate(dateKey).isNotEmpty;
  }

  /// Add an event to a date
  static Future<void> addEventToDate(
      String dateKey, Map<String, dynamic> event) async {
    final existing = get(calendarBox, dateKey) ?? {'events': []};
    final events = _normalizeEventList(existing['events']);

    // Remove old entry for same case if exists
    events.removeWhere((e) => e['caseId'] == event['caseId']);
    events.add(event);

    await put(calendarBox, dateKey, {'events': events});
  }

  static List<Map<String, dynamic>> _normalizeEventList(dynamic rawEvents) {
    if (rawEvents is! List) return <Map<String, dynamic>>[];
    return rawEvents
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // ══════════ CLEAR ALL DATA (for logout) ══════════

  static Future<void> clearAllData() async {
    await clearBox(userBox);
    await clearBox(casesBox);
    await clearBox(tasksBox);
    await clearBox(assignmentsBox);
    await clearBox(calendarBox);
    await clearBox(remindersBox);
    await clearBox(chatGroupsBox);
    await clearBox(messagesBox);
    await clearBox(noticesBox);
    await clearBox(syncQueueBox);
    await clearBox(sosBox);
    try {
      if (Hive.isBoxOpen(settingsBox)) {
        await _settingsBox.clear();
      }
    } catch (e) {
      debugPrint('Error clearing settings box: $e');
    }
  }
}