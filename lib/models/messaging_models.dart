import 'package:flutter/material.dart';
import '../utils/date_formatter.dart';

class TeamMember {
  final String id;
  final String name;
  final String role;
  final String initials;
  final Color avatarColor;

  TeamMember({
    required this.id,
    required this.name,
    required this.role,
    required this.initials,
    required this.avatarColor,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'role': role,
        'initials': initials,
        'avatarColor': avatarColor.value,
      };

  factory TeamMember.fromMap(Map<String, dynamic> map) => TeamMember(
        id: map['id'] ?? '',
        name: map['name'] ?? '',
        role: map['role'] ?? '',
        initials: map['initials'] ?? '',
        avatarColor: Color(map['avatarColor'] ?? 0xFF3C6E9F),
      );
}

class ChatGroup {
  final String id;
  final String? caseId;
  final String name;
  final String? description;
  final String createdBy;
  final String createdByName;
  final DateTime createdAt;
  final List<String> memberIds;
  final List<String> memberNames;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final bool isTemporary;
  final bool isGroup;
  final List<String> hiddenForUserIds;
  final Map<String, String> clearedAtByUser;

  ChatGroup({
    required this.id,
    this.caseId,
    required this.name,
    this.description,
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    required this.memberIds,
    required this.memberNames,
    this.lastMessage,
    this.lastMessageTime,
    this.isTemporary = true,
    this.isGroup = true,
    this.hiddenForUserIds = const [],
    this.clearedAtByUser = const {},
  });

  int get memberCount => memberIds.length;

  String getTimeAgo() {
    if (lastMessageTime == null) return 'No messages';
    final duration = DateTime.now().difference(lastMessageTime!);
    if (duration.inMinutes < 1) return 'Just now';
    if (duration.inMinutes < 60) return '${duration.inMinutes}m ago';
    if (duration.inHours < 24) return '${duration.inHours}h ago';
    if (duration.inDays < 7) return '${duration.inDays}d ago';
    return '${lastMessageTime!.day}/${lastMessageTime!.month}/${lastMessageTime!.year}';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
      'caseId': caseId,
        'name': name,
        'description': description,
        'createdBy': createdBy,
        'createdByName': createdByName,
        'createdAt': createdAt.toIso8601String(),
        'memberIds': memberIds,
        'memberNames': memberNames,
        'lastMessage': lastMessage,
        'lastMessageTime': lastMessageTime?.toIso8601String(),
        'isTemporary': isTemporary,
        'isGroup': isGroup,
        'hiddenForUserIds': hiddenForUserIds,
        'clearedAtByUser': clearedAtByUser,
      };

  factory ChatGroup.fromMap(Map<String, dynamic> map) => ChatGroup(
        id: map['id'] ?? '',
      caseId: (map['caseId'] as String?)?.trim(),
        name: map['name'] ?? '',
        description: map['description'],
        createdBy: map['createdBy'] ?? '',
        createdByName: map['createdByName'] ?? '',
        createdAt: DateFormatter.parseDate(map['createdAt']),
        memberIds: List<String>.from(map['memberIds'] ?? []),
        memberNames: List<String>.from(map['memberNames'] ?? []),
        lastMessage: map['lastMessage'],
        lastMessageTime: DateFormatter.parseDateNullable(map['lastMessageTime']),
        isTemporary: map['isTemporary'] ?? true,
          isGroup: map['isGroup'] is bool
            ? map['isGroup'] as bool
            : ((map['chatType'] ?? '').toString().toLowerCase() != 'direct'),
        hiddenForUserIds:
            List<String>.from(map['hiddenForUserIds'] ?? const []),
        clearedAtByUser: Map<String, String>.from(
            (map['clearedAtByUser'] ?? const <String, dynamic>{}) as Map),
      );
}

class ChatMessage {
  final String id;
  final String chatGroupId;
  final String senderId;
  final String senderName;
  final String senderRole;
  final String content;
  final DateTime timestamp;
  final bool isRead;
  final String? attachmentUrl;
  final String? attachmentType;
  final String? attachmentName;

  ChatMessage({
    required this.id,
    required this.chatGroupId,
    required this.senderId,
    required this.senderName,
    required this.senderRole,
    required this.content,
    required this.timestamp,
    this.isRead = false,
    this.attachmentUrl,
    this.attachmentType,
    this.attachmentName,
  });

  String getTimeDisplay() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate =
        DateTime(timestamp.year, timestamp.month, timestamp.day);

    final hour = timestamp.hour > 12
        ? timestamp.hour - 12
        : (timestamp.hour == 0 ? 12 : timestamp.hour);
    final period = timestamp.hour >= 12 ? 'PM' : 'AM';
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute $period';

    if (messageDate == today) return timeStr;
    if (messageDate == today.subtract(const Duration(days: 1))) {
      return 'Yesterday $timeStr';
    }
    return '${timestamp.day}/${timestamp.month} $timeStr';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'chatGroupId': chatGroupId,
        'senderId': senderId,
        'senderName': senderName,
        'senderRole': senderRole,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'isRead': isRead,
        'attachmentUrl': attachmentUrl,
        'attachmentType': attachmentType,
        'attachmentName': attachmentName,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
        id: map['id'] ?? '',
        chatGroupId: map['chatGroupId'] ?? '',
        senderId: map['senderId'] ?? '',
        senderName: map['senderName'] ?? '',
        senderRole: map['senderRole'] ?? '',
        content: map['content'] ?? '',
        timestamp: DateFormatter.parseDate(map['timestamp']),
        isRead: map['isRead'] ?? false,
        attachmentUrl: map['attachmentUrl'],
        attachmentType: map['attachmentType'],
        attachmentName: map['attachmentName'],
      );
}