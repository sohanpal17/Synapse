import 'package:flutter/material.dart';
import 'task_models.dart';

/// Fallback mock data used when Hive/Firestore is empty (demo mode)
class MockData {
  static final List<Member> members = [
    Member(id: 'j1', name: 'Priya Sharma', initials: 'PS', avatarColor: Colors.blue),
    Member(id: 'j2', name: 'Amit Kumar', initials: 'AK', avatarColor: Colors.green),
    Member(id: 'j3', name: 'Neha Gupta', initials: 'NG', avatarColor: Colors.purple),
    Member(id: 'j4', name: 'Rahul Verma', initials: 'RV', avatarColor: Colors.orange),
  ];

  static Member? getMemberById(String id) {
    try {
      return members.firstWhere((m) => m.id == id);
    } catch (e) {
      return null;
    }
  }
}