import 'package:flutter/material.dart';
import '../utils/date_formatter.dart';

// ==================== ENUMS ====================

enum TaskVisibility { everyone, specificMembers }

enum TaskStatus { pending, inProgress, completed, overdue }

enum AssignmentTag { urgent, highPriority, normal }

enum AssignmentStatus { pending, inProgress, completed, overdue }

enum AttachmentType { document, link, image }

// ==================== ATTACHMENT ====================

class Attachment {
  final String id;
  final AttachmentType type;
  final String name;
  final String url;
  final DateTime addedAt;

  Attachment({
    required this.id,
    required this.type,
    required this.name,
    required this.url,
    required this.addedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.name,
        'name': name,
        'url': url,
        'addedAt': addedAt.toIso8601String(),
      };

  factory Attachment.fromMap(Map<String, dynamic> map) => Attachment(
        id: map['id'] ?? '',
        type: AttachmentType.values.firstWhere(
            (e) => e.name == map['type'],
            orElse: () => AttachmentType.document),
        name: map['name'] ?? '',
        url: map['url'] ?? '',
        addedAt: DateFormatter.parseDate(map['addedAt']),
      );
}

extension AttachmentTypeExtension on AttachmentType {
  IconData get icon {
    switch (this) {
      case AttachmentType.document:
        return Icons.description;
      case AttachmentType.link:
        return Icons.link;
      case AttachmentType.image:
        return Icons.image;
    }
  }

  Color get color {
    switch (this) {
      case AttachmentType.document:
        return const Color(0xFF2196F3);
      case AttachmentType.link:
        return const Color(0xFF9C27B0);
      case AttachmentType.image:
        return const Color(0xFF4CAF50);
    }
  }
}

// ==================== COMMENT ====================

class Comment {
  final String id;
  final String authorId;
  final String authorName;
  final String authorRole;
  final String content;
  final DateTime createdAt;

  Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.authorRole,
    required this.content,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'authorRole': authorRole,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Comment.fromMap(Map<String, dynamic> map) => Comment(
        id: map['id'] ?? '',
        authorId: map['authorId'] ?? '',
        authorName: map['authorName'] ?? '',
        authorRole: map['authorRole'] ?? '',
        content: map['content'] ?? '',
        createdAt: DateFormatter.parseDate(map['createdAt']),
      );
}

// ==================== MEMBER ====================

class Member {
  final String id;
  final String name;
  final String initials;
  final Color avatarColor;

  Member({
    required this.id,
    required this.name,
    required this.initials,
    required this.avatarColor,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'initials': initials,
        'avatarColor': avatarColor.value,
      };

  factory Member.fromMap(Map<String, dynamic> map) => Member(
        id: map['id'] ?? '',
        name: map['name'] ?? '',
        initials: map['initials'] ?? '',
        avatarColor: Color(map['avatarColor'] ?? 0xFF3C6E9F),
      );
}

// ==================== TASK ====================

class Task {
  final String id;
  final String title;
  final String description;
  final String? caseId;
  final String? caseName;
  final String createdBy;
  final String createdByName;
  final DateTime createdAt;
  final DateTime deadline;
  final TaskVisibility visibility;
  final List<String> assignedMemberIds;
  final List<String> assignedMemberNames;
  final TaskStatus status;
  final bool autoEscalate;
  final bool isEscalated;
  final List<Comment> comments;
  final List<Attachment> attachments;

  Task({
    required this.id,
    required this.title,
    required this.description,
    this.caseId,
    this.caseName,
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    required this.deadline,
    required this.visibility,
    this.assignedMemberIds = const [],
    this.assignedMemberNames = const [],
    this.status = TaskStatus.pending,
    this.autoEscalate = true,
    this.isEscalated = false,
    this.comments = const [],
    this.attachments = const [],
  });

  bool isVisibleToMember(String memberId) {
    if (visibility == TaskVisibility.everyone) return true;
    if (isEscalated) return true;
    return assignedMemberIds.contains(memberId);
  }

  bool shouldEscalate() {
    if (!autoEscalate) return false;
    if (isEscalated) return false;
    if (status == TaskStatus.completed) return false;
    return DateTime.now().isAfter(deadline);
  }

  bool get hasAttachments => attachments.isNotEmpty;

  List<Attachment> getAttachmentsByType(AttachmentType type) {
    return attachments.where((a) => a.type == type).toList();
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'description': description,
        'type': 'task',
        'caseId': caseId,
        'caseName': caseName,
        'createdBy': createdBy,
        'createdByName': createdByName,
        'createdAt': createdAt.toIso8601String(),
        'deadline': deadline.toIso8601String(),
        'visibility': visibility.name,
        'assignedJuniorIds': assignedMemberIds,
        'assignedJuniorNames': assignedMemberNames,
        'status': status.name,
        'autoEscalate': autoEscalate,
        'isEscalated': isEscalated,
        'isPublic': visibility == TaskVisibility.everyone || isEscalated,
        'comments': comments.map((c) => c.toMap()).toList(),
        'attachments': attachments.map((a) => a.toMap()).toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

  factory Task.fromMap(Map<String, dynamic> map) => Task(
        id: map['id'] ?? '',
        title: map['title'] ?? '',
        description: map['description'] ?? '',
        caseId: map['caseId'],
        caseName: map['caseName'],
        createdBy: map['createdBy'] ?? '',
        createdByName: map['createdByName'] ?? '',
        createdAt: DateFormatter.parseDate(map['createdAt']),
        deadline: DateFormatter.parseDate(map['deadline']),
        visibility: TaskVisibility.values.firstWhere(
            (e) => e.name == map['visibility'],
            orElse: () => TaskVisibility.everyone),
        assignedMemberIds:
            List<String>.from(map['assignedJuniorIds'] ?? []),
        assignedMemberNames:
            List<String>.from(map['assignedJuniorNames'] ?? []),
        status: TaskStatus.values.firstWhere(
            (e) => e.name == map['status'],
            orElse: () => TaskStatus.pending),
        autoEscalate: map['autoEscalate'] ?? true,
        isEscalated: map['isEscalated'] ?? false,
        comments: (map['comments'] as List?)
                ?.map((c) => Comment.fromMap(Map<String, dynamic>.from(c)))
                .toList() ??
            [],
        attachments: (map['attachments'] as List?)
                ?.map(
                    (a) => Attachment.fromMap(Map<String, dynamic>.from(a)))
                .toList() ??
            [],
      );

  Task copyWith({
    String? id,
    String? title,
    String? description,
    String? caseId,
    String? caseName,
    String? createdBy,
    String? createdByName,
    DateTime? createdAt,
    DateTime? deadline,
    TaskVisibility? visibility,
    List<String>? assignedMemberIds,
    List<String>? assignedMemberNames,
    TaskStatus? status,
    bool? autoEscalate,
    bool? isEscalated,
    List<Comment>? comments,
    List<Attachment>? attachments,
  }) {
    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      caseId: caseId ?? this.caseId,
      caseName: caseName ?? this.caseName,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      createdAt: createdAt ?? this.createdAt,
      deadline: deadline ?? this.deadline,
      visibility: visibility ?? this.visibility,
      assignedMemberIds: assignedMemberIds ?? this.assignedMemberIds,
      assignedMemberNames: assignedMemberNames ?? this.assignedMemberNames,
      status: status ?? this.status,
      autoEscalate: autoEscalate ?? this.autoEscalate,
      isEscalated: isEscalated ?? this.isEscalated,
      comments: comments ?? this.comments,
      attachments: attachments ?? this.attachments,
    );
  }
}

// ==================== ASSIGNMENT ====================

class Assignment {
  final String id;
  final String title;
  final String description;
  final String? caseId;
  final String? caseName;
  final String createdBy;
  final String createdByName;
  final DateTime createdAt;
  final DateTime deadline;
  final String assignedToId;
  final String assignedToName;
  final AssignmentTag tag;
  final AssignmentStatus status;
  final List<Comment> comments;
  final List<Attachment> attachments;

  Assignment({
    required this.id,
    required this.title,
    required this.description,
    this.caseId,
    this.caseName,
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    required this.deadline,
    required this.assignedToId,
    required this.assignedToName,
    this.tag = AssignmentTag.normal,
    this.status = AssignmentStatus.pending,
    this.comments = const [],
    this.attachments = const [],
  });

  bool get hasAttachments => attachments.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'description': description,
        'type': 'assignment',
        'caseId': caseId,
        'caseName': caseName,
        'createdBy': createdBy,
        'createdByName': createdByName,
        'createdAt': createdAt.toIso8601String(),
        'deadline': deadline.toIso8601String(),
        'assignedToId': assignedToId,
        'assignedToName': assignedToName,
        'tag': tag.name,
        'status': status.name,
        'comments': comments.map((c) => c.toMap()).toList(),
        'attachments': attachments.map((a) => a.toMap()).toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

  factory Assignment.fromMap(Map<String, dynamic> map) => Assignment(
        id: map['id'] ?? '',
        title: map['title'] ?? '',
        description: map['description'] ?? '',
        caseId: map['caseId'],
        caseName: map['caseName'],
        createdBy: map['createdBy'] ?? '',
        createdByName: map['createdByName'] ?? '',
        createdAt: DateFormatter.parseDate(map['createdAt']),
        deadline: DateFormatter.parseDate(map['deadline']),
        assignedToId: map['assignedToId'] ?? '',
        assignedToName: map['assignedToName'] ?? '',
        tag: AssignmentTag.values.firstWhere(
            (e) => e.name == map['tag'],
            orElse: () => AssignmentTag.normal),
        status: AssignmentStatus.values.firstWhere(
            (e) => e.name == map['status'],
            orElse: () => AssignmentStatus.pending),
        comments: (map['comments'] as List?)
                ?.map((c) => Comment.fromMap(Map<String, dynamic>.from(c)))
                .toList() ??
            [],
        attachments: (map['attachments'] as List?)
                ?.map(
                    (a) => Attachment.fromMap(Map<String, dynamic>.from(a)))
                .toList() ??
            [],
      );

  Assignment copyWith({
    String? id,
    String? title,
    String? description,
    String? caseId,
    String? caseName,
    String? createdBy,
    String? createdByName,
    DateTime? createdAt,
    DateTime? deadline,
    String? assignedToId,
    String? assignedToName,
    AssignmentTag? tag,
    AssignmentStatus? status,
    List<Comment>? comments,
    List<Attachment>? attachments,
  }) {
    return Assignment(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      caseId: caseId ?? this.caseId,
      caseName: caseName ?? this.caseName,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      createdAt: createdAt ?? this.createdAt,
      deadline: deadline ?? this.deadline,
      assignedToId: assignedToId ?? this.assignedToId,
      assignedToName: assignedToName ?? this.assignedToName,
      tag: tag ?? this.tag,
      status: status ?? this.status,
      comments: comments ?? this.comments,
      attachments: attachments ?? this.attachments,
    );
  }
}

// ==================== EXTENSIONS ====================

extension TaskStatusExtension on TaskStatus {
  String get displayName {
    switch (this) {
      case TaskStatus.pending: return 'Pending';
      case TaskStatus.inProgress: return 'In Progress';
      case TaskStatus.completed: return 'Completed';
      case TaskStatus.overdue: return 'Overdue';
    }
  }

  Color get color {
    switch (this) {
      case TaskStatus.pending: return const Color(0xFFFF9800);
      case TaskStatus.inProgress: return const Color(0xFF2196F3);
      case TaskStatus.completed: return const Color(0xFF4CAF50);
      case TaskStatus.overdue: return const Color(0xFFE53935);
    }
  }
}

extension AssignmentTagExtension on AssignmentTag {
  String get displayName {
    switch (this) {
      case AssignmentTag.urgent: return 'Urgent';
      case AssignmentTag.highPriority: return 'High Priority';
      case AssignmentTag.normal: return 'Normal';
    }
  }

  Color get color {
    switch (this) {
      case AssignmentTag.urgent: return const Color(0xFFE53935);
      case AssignmentTag.highPriority: return const Color(0xFFFF9800);
      case AssignmentTag.normal: return const Color(0xFF4CAF50);
    }
  }

  IconData get icon {
    switch (this) {
      case AssignmentTag.urgent: return Icons.local_fire_department;
      case AssignmentTag.highPriority: return Icons.priority_high;
      case AssignmentTag.normal: return Icons.check_circle_outline;
    }
  }
}

extension AssignmentStatusExtension on AssignmentStatus {
  String get displayName {
    switch (this) {
      case AssignmentStatus.pending: return 'Pending';
      case AssignmentStatus.inProgress: return 'In Progress';
      case AssignmentStatus.completed: return 'Completed';
      case AssignmentStatus.overdue: return 'Overdue';
    }
  }

  Color get color {
    switch (this) {
      case AssignmentStatus.pending: return const Color(0xFFFF9800);
      case AssignmentStatus.inProgress: return const Color(0xFF2196F3);
      case AssignmentStatus.completed: return const Color(0xFF4CAF50);
      case AssignmentStatus.overdue: return const Color(0xFFE53935);
    }
  }
}