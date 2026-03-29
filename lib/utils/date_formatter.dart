import 'package:cloud_firestore/cloud_firestore.dart';

class DateFormatter {
  /// Safely parses a dynamic Date object (String, Timestamp, or null) into a required DateTime.
  /// Defaults to [DateTime.now()] if parsing fails or input is null.
  static DateTime parseDate(dynamic val) {
    if (val == null) return DateTime.now();
    if (val is Timestamp) return val.toDate();
    if (val is String) return DateTime.tryParse(val) ?? DateTime.now();
    return DateTime.now();
  }

  /// Safely parses a dynamic Date object into a nullable DateTime.
  static DateTime? parseDateNullable(dynamic val) {
    if (val == null) return null;
    if (val is Timestamp) return val.toDate();
    if (val is String) return DateTime.tryParse(val);
    return null;
  }
}
