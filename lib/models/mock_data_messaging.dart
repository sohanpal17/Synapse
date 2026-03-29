import 'package:flutter/material.dart';
import 'messaging_models.dart';

/// Mock data for messaging features (team members, chat groups, messages)
class MessagingMockData {
  static final List<TeamMember> teamMembers = [
    TeamMember(
      id: 's1',
      name: 'Adv. Rajesh Sharma',
      role: 'Lawyer',
      initials: 'RS',
      avatarColor: const Color(0xFF0F2A44),
    ),
    TeamMember(
      id: 's2',
      name: 'Adv. Priya Patel',
      role: 'Lawyer',
      initials: 'PP',
      avatarColor: const Color(0xFF3C6E9F),
    ),
    TeamMember(
      id: 'j1',
      name: 'Priya Sharma',
      role: 'Junior Lawyer',
      initials: 'PS',
      avatarColor: Colors.blue,
    ),
    TeamMember(
      id: 'j2',
      name: 'Amit Kumar',
      role: 'Junior Lawyer',
      initials: 'AK',
      avatarColor: Colors.green,
    ),
    TeamMember(
      id: 'i1',
      name: 'Neha Gupta',
      role: 'Intern',
      initials: 'NG',
      avatarColor: Colors.purple,
    ),
    TeamMember(
      id: 'i2',
      name: 'Rahul Verma',
      role: 'Intern',
      initials: 'RV',
      avatarColor: Colors.orange,
    ),
  ];

  static TeamMember? getTeamMember(String id) {
    try {
      return teamMembers.firstWhere((m) => m.id == id);
    } catch (e) {
      return null;
    }
  }

  static List<ChatGroup> getChatGroupsForUser(String userId) {
    return _chatGroups
        .where((g) => g.memberIds.contains(userId))
        .toList()
      ..sort((a, b) {
        final aTime = a.lastMessageTime ?? a.createdAt;
        final bTime = b.lastMessageTime ?? b.createdAt;
        return bTime.compareTo(aTime);
      });
  }

  static List<ChatMessage> getMessagesForChat(String chatGroupId) {
    return _messages
        .where((m) => m.chatGroupId == chatGroupId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  // ── Mock Chat Groups ──
  static final List<ChatGroup> _chatGroups = [
    ChatGroup(
      id: 'cg1',
      name: 'Case Discussion - Singh vs State',
      createdBy: 's1',
      createdByName: 'Adv. Rajesh Sharma',
      createdAt: DateTime.now().subtract(const Duration(days: 5)),
      memberIds: ['s1', 's2', 'j1', 'i1'],
      memberNames: [
        'Adv. Rajesh Sharma',
        'Adv. Priya Patel',
        'Priya Sharma',
        'Neha Gupta'
      ],
      lastMessage: 'Please prepare the brief by tomorrow.',
      lastMessageTime: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    ChatGroup(
      id: 'cg2',
      name: 'Team Updates',
      createdBy: 's1',
      createdByName: 'Adv. Rajesh Sharma',
      createdAt: DateTime.now().subtract(const Duration(days: 10)),
      memberIds: ['s1', 's2', 'j1', 'j2', 'i1', 'i2'],
      memberNames: [
        'Adv. Rajesh Sharma',
        'Adv. Priya Patel',
        'Priya Sharma',
        'Amit Kumar',
        'Neha Gupta',
        'Rahul Verma'
      ],
      lastMessage: 'Meeting at 3 PM today.',
      lastMessageTime: DateTime.now().subtract(const Duration(hours: 5)),
    ),
    ChatGroup(
      id: 'cg3',
      name: 'Document Review',
      createdBy: 's2',
      createdByName: 'Adv. Priya Patel',
      createdAt: DateTime.now().subtract(const Duration(days: 2)),
      memberIds: ['s1', 's2', 'j2'],
      memberNames: [
        'Adv. Rajesh Sharma',
        'Adv. Priya Patel',
        'Amit Kumar'
      ],
      lastMessage: 'I have uploaded the revised draft.',
      lastMessageTime: DateTime.now().subtract(const Duration(minutes: 30)),
    ),
  ];

  // ── Mock Messages ──
  static final List<ChatMessage> _messages = [
    ChatMessage(
      id: 'm1',
      chatGroupId: 'cg1',
      senderId: 's1',
      senderName: 'Adv. Rajesh Sharma',
      senderRole: 'Lawyer',
      content: 'Have we received the witness statements?',
      timestamp: DateTime.now().subtract(const Duration(hours: 4)),
    ),
    ChatMessage(
      id: 'm2',
      chatGroupId: 'cg1',
      senderId: 'j1',
      senderName: 'Priya Sharma',
      senderRole: 'Junior Lawyer',
      content: 'Yes, I have compiled all witness statements. Sending the file now.',
      timestamp: DateTime.now().subtract(const Duration(hours: 3)),
    ),
    ChatMessage(
      id: 'm3',
      chatGroupId: 'cg1',
      senderId: 's1',
      senderName: 'Adv. Rajesh Sharma',
      senderRole: 'Lawyer',
      content: 'Please prepare the brief by tomorrow.',
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    ChatMessage(
      id: 'm4',
      chatGroupId: 'cg2',
      senderId: 's1',
      senderName: 'Adv. Rajesh Sharma',
      senderRole: 'Lawyer',
      content: 'Meeting at 3 PM today.',
      timestamp: DateTime.now().subtract(const Duration(hours: 5)),
    ),
    ChatMessage(
      id: 'm5',
      chatGroupId: 'cg3',
      senderId: 's2',
      senderName: 'Adv. Priya Patel',
      senderRole: 'Lawyer',
      content: 'I have uploaded the revised draft.',
      timestamp: DateTime.now().subtract(const Duration(minutes: 30)),
    ),
  ];
}
