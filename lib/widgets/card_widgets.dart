import 'package:flutter/material.dart';
import '../main.dart';
import '../models/reminder_models.dart';
import '../models/messaging_models.dart';
import '../models/notice_models.dart';

// ══════════ REMINDER CARD ══════════

class ReminderCard extends StatelessWidget {
  final Reminder reminder;
  final VoidCallback? onTap;
  final ValueChanged<bool?>? onCheckChanged;

  const ReminderCard({
    super.key,
    required this.reminder,
    this.onTap,
    this.onCheckChanged,
  });

  @override
  Widget build(BuildContext context) {
    final urgencyColor = reminder.getUrgencyColor();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.white,
        elevation: 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border(
                left: BorderSide(color: urgencyColor, width: 4),
              ),
            ),
            child: Row(
              children: [
                // Checkbox
                GestureDetector(
                  onTap: () => onCheckChanged?.call(!reminder.isCompleted),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: reminder.isCompleted
                            ? Colors.grey
                            : urgencyColor,
                        width: 2,
                      ),
                      color: reminder.isCompleted
                          ? Colors.grey.withOpacity(0.3)
                          : Colors.transparent,
                    ),
                    child: reminder.isCompleted
                        ? const Icon(Icons.check, size: 16, color: Colors.grey)
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reminder.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: reminder.isCompleted
                              ? Colors.grey
                              : AppColors.text,
                          decoration: reminder.isCompleted
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.schedule,
                            size: 14,
                            color: urgencyColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            reminder.getTimeRemaining(),
                            style: TextStyle(
                              fontSize: 12,
                              color: urgencyColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: urgencyColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              reminder.getUrgencyLabel(),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: urgencyColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: Colors.grey[400],
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════ CHAT GROUP CARD ══════════

class ChatGroupCard extends StatelessWidget {
  final ChatGroup chatGroup;
  final String? currentUserId;
  final String? directMemberRole;
  final VoidCallback? onTap;

  const ChatGroupCard({
    super.key,
    required this.chatGroup,
    this.currentUserId,
    this.directMemberRole,
    this.onTap,
  });

  String get _displayName {
    if (chatGroup.memberCount == 2 && currentUserId != null) {
      final otherIndex = chatGroup.memberIds.indexWhere((id) => id != currentUserId);
      if (otherIndex != -1 && otherIndex < chatGroup.memberNames.length) {
        return chatGroup.memberNames[otherIndex].replaceAll(' (You)', '');
      }
    }
    return chatGroup.name;
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _displayName;
    final isDirect = chatGroup.memberCount == 2;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.white,
        elevation: 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Group avatar
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      displayName.isNotEmpty
                          ? displayName.substring(0, 1).toUpperCase()
                          : '?',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      if (chatGroup.lastMessage != null)
                        Text(
                          chatGroup.lastMessage!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            isDirect ? Icons.person : Icons.group,
                            size: 14,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isDirect
                                ? ((directMemberRole ?? 'member').toUpperCase())
                                : '${chatGroup.memberCount} members',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                          ),
                          const Spacer(),
                          Text(
                            chatGroup.getTimeAgo(),
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════ NOTICE CARD ══════════

class NoticeCard extends StatelessWidget {
  final Notice notice;
  final VoidCallback? onTap;

  const NoticeCard({
    super.key,
    required this.notice,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.white,
        elevation: 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  children: [
                    if (notice.isPinned) ...[
                      Icon(
                        Icons.push_pin,
                        size: 16,
                        color: AppColors.primary.withOpacity(0.7),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        notice.title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: notice.priority.color.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            notice.priority.icon,
                            size: 12,
                            color: notice.priority.color,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            notice.priority.displayName,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: notice.priority.color,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Content preview
                Text(
                  notice.content,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                // Footer
                Row(
                  children: [
                    Icon(
                      Icons.person_outline,
                      size: 14,
                      color: Colors.grey[500],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      notice.authorName,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                      ),
                    ),
                    const Spacer(),
                    Text(
                      notice.getTimeAgo(),
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
