import 'package:flutter/material.dart';
import '../utils/date_formatter.dart';

class UserModel {
  final String uid;
  final String name;
  final String email;
  final String phone;
  final String role; // 'lawyer', 'intern', 'client', 'admin'
  final String approvalStatus; // 'pending', 'approved', 'rejected'
  final bool isActive;
  final String initials;
  final DateTime createdAt;

  static String _deriveInitials(String rawName) {
    final parts = rawName
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    return parts.map((w) => w[0].toUpperCase()).take(2).join();
  }

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    this.phone = '',
    required this.role,
    this.approvalStatus = 'approved',
    this.isActive = true,
    String? initials,
    DateTime? createdAt,
  })  : initials = initials ?? _deriveInitials(name),
        createdAt = createdAt ?? DateTime.now();

  // ── Role Helpers ──
  bool get isLawyer => role == 'lawyer';
  bool get isIntern => role == 'intern';
  bool get isClient => role == 'client';
  bool get isAdmin => role == 'admin';
  bool get isApproved => approvalStatus == 'approved';

  /// Lawyers and interns are internal team members
  bool get isTeamMember => isLawyer || isIntern;

  Color get avatarColor => const Color(0xFF3C6E9F);

  // ── Serialization ──
  Map<String, dynamic> toMap() => {
        'uid': uid,
        'name': name,
        'email': email,
        'phone': phone,
        'role': role,
        'approvalStatus': approvalStatus,
        'isActive': isActive,
        'initials': initials,
        'createdAt': createdAt.toIso8601String(),
      };

  factory UserModel.fromMap(Map<String, dynamic> map) => UserModel(
        uid: map['uid']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        email: map['email']?.toString() ?? '',
        phone: map['phone']?.toString() ?? '',
        role: map['role']?.toString() ?? 'lawyer',
        approvalStatus: map['approvalStatus']?.toString() ?? 'approved',
        isActive: map['isActive'] is bool ? map['isActive'] as bool : true,
        // Keep avatar initials in sync with latest name everywhere in the app.
        initials: _deriveInitials(map['name']?.toString() ?? ''),
        createdAt: DateFormatter.parseDate(map['createdAt']),
      );

  /// Create a copy with updated fields
  UserModel copyWith({
    String? name,
    String? phone,
    String? role,
    String? approvalStatus,
    bool? isActive,
  }) {
    return UserModel(
      uid: uid,
      name: name ?? this.name,
      email: email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      approvalStatus: approvalStatus ?? this.approvalStatus,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
    );
  }

  @override
  String toString() => 'UserModel(name: $name, role: $role)';
}