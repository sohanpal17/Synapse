import 'package:flutter/material.dart';
import '../utils/date_formatter.dart';

class UserModel {
  final String uid;
  final String name;
  final String email;
  final String phone;
  final String role; // 'lawyer', 'intern', 'client'
  final String initials;
  final DateTime createdAt;

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    this.phone = '',
    required this.role,
    String? initials,
    DateTime? createdAt,
  })  : initials = initials ??
            name
                .split(' ')
                .where((w) => w.isNotEmpty)
                .map((w) => w[0].toUpperCase())
                .take(2)
                .join(),
        createdAt = createdAt ?? DateTime.now();

  // ── Role Helpers ──
  bool get isLawyer => role == 'lawyer';
  bool get isIntern => role == 'intern';
  bool get isClient => role == 'client';

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
        'initials': initials,
        'createdAt': createdAt.toIso8601String(),
      };

  factory UserModel.fromMap(Map<String, dynamic> map) => UserModel(
        uid: map['uid']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        email: map['email']?.toString() ?? '',
        phone: map['phone']?.toString() ?? '',
        role: map['role']?.toString() ?? 'lawyer',
        initials: map['initials']?.toString(),
        createdAt: DateFormatter.parseDate(map['createdAt']),
      );

  /// Create a copy with updated fields
  UserModel copyWith({
    String? name,
    String? phone,
    String? role,
  }) {
    return UserModel(
      uid: uid,
      name: name ?? this.name,
      email: email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      createdAt: createdAt,
    );
  }

  @override
  String toString() => 'UserModel(name: $name, role: $role)';
}