import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../main.dart';
import '../widgets/common_widgets.dart';
import '../widgets/card_widgets.dart';
import '../models/notice_models.dart';
import '../providers/providers.dart';

// ==================== NOTICE BOARD SCREEN ====================
class NoticeBoardScreen extends ConsumerStatefulWidget {
  const NoticeBoardScreen({super.key});

  @override
  ConsumerState<NoticeBoardScreen> createState() => _NoticeBoardScreenState();
}

class _NoticeBoardScreenState extends ConsumerState<NoticeBoardScreen> {
  @override
  Widget build(BuildContext context) {
    final allNotices = ref.watch(noticesProvider);
    final pinnedNotices = allNotices.where((n) => n.isPinned).toList();
    final unpinnedNotices = allNotices.where((n) => !n.isPinned).toList();

    return Scaffold(
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text(
                  'Notice Board',
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${allNotices.length} ${allNotices.length == 1 ? 'Notice' : 'Notices'}',
                    style: const TextStyle(
                      color: AppColors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: allNotices.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.campaign_outlined,
                            size: 80,
                            color: Colors.grey[300],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No notices yet',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Be the first to post a notice',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[500],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Pinned Notices Section
                        if (pinnedNotices.isNotEmpty) ...[
                          Row(
                            children: [
                              const Icon(Icons.push_pin, size: 16, color: AppColors.primary),
                              const SizedBox(width: 6),
                              const Text(
                                'Pinned Notices',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ...pinnedNotices.map((notice) {
                            return NoticeCard(
                              notice: notice,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => NoticeDetailScreen(notice: notice),
                                  ),
                                ).then((_) => setState(() {}));
                              },
                            );
                          }).toList(),
                          const SizedBox(height: 24),
                        ],

                        // All Notices Section
                        if (unpinnedNotices.isNotEmpty) ...[
                          const Text(
                            'All Notices',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ...unpinnedNotices.map((notice) {
                            return NoticeCard(
                              notice: notice,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => NoticeDetailScreen(notice: notice),
                                  ),
                                ).then((_) => setState(() {}));
                              },
                            );
                          }).toList(),
                        ],

                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const CreateNoticeScreen(),
            ),
          ).then((_) => setState(() {}));
        },
        backgroundColor: AppColors.accent,
        icon: const Icon(Icons.add, color: AppColors.primary),
        label: const Text(
          'Add Notice',
          style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

// ==================== NOTIFICATIONS SCREEN ====================
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  String _filter = 'all';

  String _categoryForType(String typeRaw) {
    final type = typeRaw.toLowerCase().trim();
    if (type.contains('task')) return 'task';
    if (type.contains('assignment')) return 'assignment';
    if (type.contains('escalation') || type.contains('escalated')) return 'escalation';
    if (type.contains('viewed')) return 'viewed';
    if (type.contains('comment')) return 'comment';
    return 'other';
  }

  String _labelForType(String typeRaw) {
    final type = typeRaw.toLowerCase().trim();
    switch (type) {
      case 'task_created':
        return 'Task Created';
      case 'task_escalated':
        return 'Task Escalated';
      case 'task_viewed':
        return 'Task Viewed';
      case 'task_comment':
        return 'Task Comment';
      case 'assignment_created':
        return 'Assignment Created';
      case 'assignment_status':
        return 'Assignment Status';
      case 'assignment_viewed':
        return 'Assignment Viewed';
      case 'assignment_comment':
        return 'Assignment Comment';
      default:
        return typeRaw.trim().isEmpty ? 'Notification' : typeRaw;
    }
  }

  String _timeAgo(dynamic createdAt) {
    final dt = DateTime.tryParse((createdAt ?? '').toString());
    if (dt == null) return '';
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final notificationsAsync = ref.watch(inAppNotificationsProvider);

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text(
                  'Notifications',
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          notificationsAsync.when(
            data: (items) {
              final filtered = items.where((n) {
                if (_filter == 'all') return true;
                final category = _categoryForType((n['type'] ?? '').toString());
                return category == _filter;
              }).toList();

              return Expanded(
                child: Column(
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      child: Row(
                        children: [
                          for (final chip in const [
                            {'key': 'all', 'label': 'All'},
                            {'key': 'task', 'label': 'Tasks'},
                            {'key': 'assignment', 'label': 'Assignments'},
                            {'key': 'escalation', 'label': 'Escalations'},
                            {'key': 'viewed', 'label': 'Viewed'},
                            {'key': 'comment', 'label': 'Comments'},
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(chip['label']!),
                                selected: _filter == chip['key'],
                                onSelected: (_) {
                                  setState(() => _filter = chip['key']!);
                                },
                                selectedColor: AppColors.accent.withOpacity(0.25),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                'No notifications',
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final n = filtered[index];
                                final isRead = n['isRead'] == true;
                                final type = (n['type'] ?? '').toString();
                                final title = (n['title'] ?? 'Notification').toString();
                                final body = (n['body'] ?? '').toString();
                                final notifId = (n['id'] ?? '').toString();

                                return GestureDetector(
                                  onTap: () async {
                                    if (!isRead && notifId.isNotEmpty) {
                                      await ref
                                          .read(firestoreServiceProvider)
                                          .markNotificationRead(notifId);
                                    }
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isRead
                                          ? AppColors.white
                                          : AppColors.accent.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isRead
                                            ? Colors.grey.withOpacity(0.2)
                                            : AppColors.accent.withOpacity(0.45),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                title,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  color: AppColors.text,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              _timeAgo(n['createdAt']),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey[600],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _labelForType(type),
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.blueGrey[700],
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (body.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            body,
                                            style: TextStyle(
                                                color: Colors.grey[800],
                                                fontSize: 13),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              );
            },
            loading: () => const Expanded(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Expanded(
              child: Center(
                child: Text(
                  'Unable to load notifications',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== CREATE NOTICE SCREEN ====================
class CreateNoticeScreen extends ConsumerStatefulWidget {
  const CreateNoticeScreen({super.key});

  @override
  ConsumerState<CreateNoticeScreen> createState() => _CreateNoticeScreenState();
}

class _CreateNoticeScreenState extends ConsumerState<CreateNoticeScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  NoticePriority _priority = NoticePriority.normal;
  bool _isPinned = false;

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _postNotice() {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a title')),
      );
      return;
    }

    if (_contentController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter notice content')),
      );
      return;
    }

    final user = ref.read(currentUserProvider);
    if (user == null) return;

    final notice = Notice(
      id: const Uuid().v4(),
      title: _titleController.text.trim(),
      content: _contentController.text.trim(),
      authorId: user.uid,
      authorName: user.name,
      authorRole: user.role,
      createdAt: DateTime.now(),
      priority: _priority,
      isPinned: _isPinned,
    );

    ref.read(noticesProvider.notifier).addNotice(notice);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Notice "${_titleController.text}" posted successfully',
          style: const TextStyle(color: AppColors.white),
        ),
        backgroundColor: AppColors.success,
      ),
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text(
                  'Create Notice',
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  const Text(
                    'Title',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _titleController,
                    decoration: InputDecoration(
                      hintText: 'Enter notice title',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.primary, width: 2),
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Content
                  const Text(
                    'Content',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _contentController,
                    maxLines: 6,
                    decoration: InputDecoration(
                      hintText: 'Enter notice content',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.primary, width: 2),
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Priority
                  const Text(
                    'Priority',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _priority = NoticePriority.normal),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: _priority == NoticePriority.normal
                                  ? AppColors.success.withOpacity(0.1)
                                  : AppColors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _priority == NoticePriority.normal
                                    ? AppColors.success
                                    : Colors.grey[300]!,
                                width: 2,
                              ),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: _priority == NoticePriority.normal
                                      ? AppColors.success
                                      : Colors.grey[400],
                                  size: 28,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Normal',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: _priority == NoticePriority.normal
                                        ? AppColors.success
                                        : Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _priority = NoticePriority.important),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: _priority == NoticePriority.important
                                  ? AppColors.error.withOpacity(0.1)
                                  : AppColors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _priority == NoticePriority.important
                                    ? AppColors.error
                                    : Colors.grey[300]!,
                                width: 2,
                              ),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.priority_high,
                                  color: _priority == NoticePriority.important
                                      ? AppColors.error
                                      : Colors.grey[400],
                                  size: 28,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Important',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: _priority == NoticePriority.important
                                        ? AppColors.error
                                        : Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Pin Option
                  GestureDetector(
                    onTap: () => setState(() => _isPinned = !_isPinned),
                    child: AppCard(
                      child: Row(
                        children: [
                          Checkbox(
                            value: _isPinned,
                            onChanged: (value) => setState(() => _isPinned = value ?? false),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            activeColor: AppColors.primary,
                          ),
                          const SizedBox(width: 12),
                          const Icon(Icons.push_pin, color: AppColors.primary, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Pin this notice',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.text,
                                  ),
                                ),
                                Text(
                                  'Pinned notices appear at the top',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Post Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _postNotice,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Post Notice',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== NOTICE DETAIL SCREEN ====================
class NoticeDetailScreen extends ConsumerWidget {
  final Notice notice;

  const NoticeDetailScreen({super.key, required this.notice});

  Future<void> _deleteNotice(BuildContext context, WidgetRef ref) async {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Notice'),
        content: const Text('Are you sure you want to delete this notice?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext); // Close dialog
              try {
                await ref.read(noticesProvider.notifier).deleteNotice(notice.id);
                if (!context.mounted) return;
                Navigator.pop(context); // Close detail screen
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Notice deleted'),
                    backgroundColor: AppColors.error,
                  ),
                );
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Unable to delete notice'),
                    backgroundColor: AppColors.error,
                  ),
                );
              }
            },
            child: const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final currentUserId = user?.uid ?? '';
    final isAuthor = notice.authorId == currentUserId;

    return Scaffold(
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            decoration: BoxDecoration(
              color: notice.priority.color,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(Icons.arrow_back, color: AppColors.white, size: 20),
                      ),
                    ),
                    const Spacer(),
                    if (notice.isPinned)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.push_pin, color: AppColors.white, size: 14),
                            SizedBox(width: 4),
                            Text(
                              'Pinned',
                              style: TextStyle(
                                color: AppColors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (isAuthor) ...[
                      const SizedBox(width: 8),
                      PopupMenuButton(
                        icon: const Icon(Icons.more_vert, color: AppColors.white),
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete, size: 20, color: AppColors.error),
                                SizedBox(width: 12),
                                Text('Delete', style: TextStyle(color: AppColors.error)),
                              ],
                            ),
                          ),
                        ],
                        onSelected: (value) {
                          if (value == 'delete') {
                            _deleteNotice(context, ref);
                          }
                        },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(notice.priority.icon, color: AppColors.white, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      notice.priority.displayName,
                      style: const TextStyle(
                        color: AppColors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text(
                    notice.title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Author & Date
                  AppCard(
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: AppColors.primary,
                          radius: 20,
                          child: Text(
                            notice.authorName.split(' ').map((n) => n[0]).take(2).join(),
                            style: const TextStyle(
                              color: AppColors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                notice.authorName,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.text,
                                ),
                              ),
                              Text(
                                '${notice.authorRole} • ${notice.getTimeAgo()}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Content
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Notice Content',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.text,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          notice.content,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Details
                  AppCard(
                    child: Column(
                      children: [
                        _buildDetailRow('Posted On', notice.getFormattedDate()),
                        const Divider(height: 24),
                        _buildDetailRow('Priority', notice.priority.displayName),
                        const Divider(height: 24),
                        _buildDetailRow('Status', notice.isPinned ? 'Pinned' : 'Active'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[600],
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
        ),
      ],
    );
  }
}

// Helper widget for back button
Widget _buildBackButton(BuildContext context) {
  return Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: AppColors.white.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
    ),
    child: IconButton(
      icon: const Icon(Icons.arrow_back, color: AppColors.white, size: 20),
      onPressed: () => Navigator.pop(context),
    ),
  );
}
