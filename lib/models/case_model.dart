import 'package:flutter/material.dart';
import '../main.dart';
import '../utils/date_formatter.dart';

class CaseModel {
  // ── Primary Identifier ──
  final String cino;

  // ── Display Fields ──
  final String title;
  final String petitioner;
  final String respondent;
  final String caseNumber;
  final String caseType;
  final int year;
  final int? regNo;

  // ── Court Details (for SOS & Clustering) ──
  final String courtComplex;
  final String courtRoom;
  final String district;
  final String state;

  // ── Calendar & Status ──
  final DateTime? nextHearingDate;
  final DateTime? lastHearingDate;
  final String currentStage;
  final DateTime? decisionDate;
  final String? disposalStatus;

  // ── Computed Fields ──
  final bool isClosed;
  final String urgencyLevel;

  // ── Firm & Team ──
  final List<String> assignedMemberIds;
  final List<String> clientIds;

  // ── Documents ──
  final List<Map<String, dynamic>> customDocuments;

  // ── Timestamps ──
  final DateTime createdAt;
  final DateTime updatedAt;

  CaseModel({
    required this.cino,
    required this.title,
    required this.petitioner,
    required this.respondent,
    required this.caseNumber,
    required this.caseType,
    required this.year,
    this.regNo,
    required this.courtComplex,
    required this.courtRoom,
    required this.district,
    required this.state,
    this.nextHearingDate,
    this.lastHearingDate,
    required this.currentStage,
    this.decisionDate,
    this.disposalStatus,
    required this.isClosed,
    required this.urgencyLevel,
    this.assignedMemberIds = const [],
    this.clientIds = const [],
    this.customDocuments = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  // ══════════ URGENCY CALCULATION ══════════
  /// Traffic light system:
  /// Green  → more than 7 days remaining
  /// Yellow → 3 to 7 days remaining
  /// Red    → less than 48 hours remaining
  /// None   → no hearing date or case closed
  static String computeUrgency(DateTime? nextDate) {
    if (nextDate == null) return 'none';

    final hoursRemaining = nextDate.difference(DateTime.now()).inHours;

    if (hoursRemaining < 0) return 'red'; // Overdue
    if (hoursRemaining < 48) return 'red';
    if (hoursRemaining < 168) return 'yellow'; // 7 days = 168 hours
    return 'green';
  }

  /// Returns the color based on urgency level
  Color get urgencyColor {
    switch (urgencyLevel) {
      case 'red':
        return AppColors.urgencyRed;
      case 'yellow':
        return AppColors.urgencyYellow;
      case 'green':
        return AppColors.urgencyGreen;
      default:
        return AppColors.grey;
    }
  }

  /// Display text for case status
  String get statusText => isClosed ? 'Disposed' : 'Pending';

  // ══════════ SERIALIZATION ══════════
  Map<String, dynamic> toMap() => {
        'cino': cino,
        'title': title,
        'petitioner': petitioner,
        'respondent': respondent,
        'caseNumber': caseNumber,
        'caseType': caseType,
        'year': year,
        'regNo': regNo,
        'courtComplex': courtComplex,
        'courtRoom': courtRoom,
        'district': district,
        'state': state,
        'nextHearingDate': nextHearingDate?.toIso8601String(),
        'lastHearingDate': lastHearingDate?.toIso8601String(),
        'currentStage': currentStage,
        'decisionDate': decisionDate?.toIso8601String(),
        'disposalStatus': disposalStatus,
        'isClosed': isClosed,
        'urgencyLevel': urgencyLevel,
        'assignedLawyerIds': assignedMemberIds, // Keep old keys for backward sync
        'assignedInternIds': [],
        'assignedMemberIds': assignedMemberIds,
        'clientIds': clientIds,
        'customDocuments': customDocuments,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory CaseModel.fromMap(Map<String, dynamic> map) {
    final nextDate = DateFormatter.parseDateNullable(map['nextHearingDate']);
    final decDate = DateFormatter.parseDateNullable(map['decisionDate']);

    return CaseModel(
      cino: map['cino'] ?? '',
      title: map['title'] ?? '',
      petitioner: map['petitioner'] ?? '',
      respondent: map['respondent'] ?? '',
      caseNumber: map['caseNumber'] ?? '',
      caseType: map['caseType'] ?? '',
      year: _toInt(map['year']),
      regNo: map['regNo'] != null ? _toInt(map['regNo']) : null,
      courtComplex: map['courtComplex'] ?? '',
      courtRoom: map['courtRoom'] ?? '',
      district: map['district'] ?? '',
      state: map['state'] ?? '',
      nextHearingDate: nextDate,
      lastHearingDate: DateFormatter.parseDateNullable(map['lastHearingDate']),
      currentStage: map['currentStage'] ?? '',
      decisionDate: decDate,
      disposalStatus: map['disposalStatus'],
      isClosed: decDate != null,
      urgencyLevel: computeUrgency(nextDate),
      assignedMemberIds: [
        ...List<String>.from(map['assignedMemberIds'] ?? []),
        ...List<String>.from(map['assignedLawyerIds'] ?? []),
        ...List<String>.from(map['assignedInternIds'] ?? []),
        ...List<String>.from(map['clientIds'] ?? []),
      ].toSet().toList(),
      clientIds: List<String>.from(map['clientIds'] ?? []),
      customDocuments: List<Map<String, dynamic>>.from(map['customDocuments'] ?? []),
      createdAt: DateFormatter.parseDate(map['createdAt']),
      updatedAt: DateFormatter.parseDate(map['updatedAt']),
    );
  }

  // ══════════ eCOURTS IMPORT FACTORY ══════════
  /// Transforms raw eCourts JSON into a clean CaseModel
  factory CaseModel.fromEcourtsJson(Map<String, dynamic> raw) {
    String cleanParty(dynamic value, String fallback) {
      if (value == null) return fallback;
      final str = value.toString().trim();
      if (str.isEmpty || RegExp(r'^X{3,}$', caseSensitive: false).hasMatch(str)) {
        return fallback;
      }
      return str;
    }

    final pet = cleanParty(raw['petparty_name'], 'Unknown Petitioner');
    final res = cleanParty(raw['resparty_name'], 'Unknown Respondent');
    final caseType = raw['type_name'] ?? '';
    final regYear = raw['reg_year'];
    final regNo = raw['reg_no'];
    final caseNo = raw['case_no'] ?? '';
    final nextDateStr = raw['date_next_list'];
    final decDateStr = raw['date_of_decision'];
    final lastDateStr = raw['date_last_list'];

    final nextDate = nextDateStr != null ? DateTime.tryParse(nextDateStr) : null;
    final decDate = decDateStr != null ? DateTime.tryParse(decDateStr) : null;
    final lastDate = lastDateStr != null ? DateTime.tryParse(lastDateStr) : null;

    final parsedYear = _toInt(regYear);
    final parsedRegNo = regNo != null ? _toInt(regNo) : null;

    return CaseModel(
      cino: raw['cino'] ?? caseNo,
      title: '$pet vs $res',
      petitioner: pet,
      respondent: res,
      caseNumber: '$caseType ${parsedRegNo ?? ""}/$parsedYear',
      caseType: caseType,
      year: parsedYear,
      regNo: parsedRegNo,
      courtComplex: raw['establishment_name'] ?? '',
      courtRoom: raw['court_no_desg_name'] ?? '',
      district: raw['district_name'] ?? '',
      state: raw['state_name'] ?? '',
      nextHearingDate: nextDate,
      lastHearingDate: lastDate,
      currentStage: raw['purpose_name'] ?? '',
      decisionDate: decDate,
      disposalStatus: (raw['disp_name'] != null && raw['disp_name'].toString().isNotEmpty)
          ? raw['disp_name']
          : null,
      isClosed: decDate != null,
      urgencyLevel: computeUrgency(nextDate),
    );
  }

  // ══════════ COPY WITH ══════════
  CaseModel copyWith({
    List<String>? assignedMemberIds,
    List<String>? clientIds,
    List<Map<String, dynamic>>? customDocuments,
    DateTime? nextHearingDate,
    String? currentStage,
    String? courtRoom,
  }) {
    final nd = nextHearingDate ?? this.nextHearingDate;
    return CaseModel(
      cino: cino,
      title: title,
      petitioner: petitioner,
      respondent: respondent,
      caseNumber: caseNumber,
      caseType: caseType,
      year: year,
      regNo: regNo,
      courtComplex: courtComplex,
      courtRoom: courtRoom ?? this.courtRoom,
      district: district,
      state: state,
      nextHearingDate: nd,
      lastHearingDate: lastHearingDate,
      currentStage: currentStage ?? this.currentStage,
      decisionDate: decisionDate,
      disposalStatus: disposalStatus,
      isClosed: isClosed,
      urgencyLevel: CaseModel.computeUrgency(nd),
      assignedMemberIds: assignedMemberIds ?? this.assignedMemberIds,
      clientIds: clientIds ?? this.clientIds,
      customDocuments: customDocuments ?? this.customDocuments,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  // ══════════ HELPER ══════════
  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  @override
  String toString() => 'CaseModel(cino: $cino, title: $title, closed: $isClosed)';
}