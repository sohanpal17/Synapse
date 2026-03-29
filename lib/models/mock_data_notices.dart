import 'notice_models.dart';

/// Mock data for notice board features
class NoticeMockData {
  static List<Notice> getAllNotices() {
    return List.from(_notices)
      ..sort((a, b) {
        // Pinned first, then by date descending
        if (a.isPinned && !b.isPinned) return -1;
        if (!a.isPinned && b.isPinned) return 1;
        return b.createdAt.compareTo(a.createdAt);
      });
  }

  // ── Mock Data ──
  static final List<Notice> _notices = [
    Notice(
      id: 'n1',
      title: 'Office Closed - Republic Day',
      content:
          'The office will remain closed on 26th January on account of Republic Day. '
          'All hearings scheduled for that day have been rescheduled. Please check the '
          'calendar for updated dates.',
      authorId: 's1',
      authorName: 'Adv. Rajesh Sharma',
      authorRole: 'Lawyer',
      createdAt: DateTime.now().subtract(const Duration(days: 1)),
      priority: NoticePriority.important,
      isPinned: true,
    ),
    Notice(
      id: 'n2',
      title: 'New Filing Procedure Update',
      content:
          'The High Court has introduced a new e-filing procedure effective from next month. '
          'All team members must complete the online training module by the end of this week. '
          'Login credentials will be shared via email.',
      authorId: 's2',
      authorName: 'Adv. Priya Patel',
      authorRole: 'Lawyer',
      createdAt: DateTime.now().subtract(const Duration(days: 3)),
      priority: NoticePriority.normal,
      isPinned: false,
    ),
    Notice(
      id: 'n3',
      title: 'Weekly Case Review Meeting',
      content:
          'Weekly case review meeting will be held every Monday at 10 AM in the conference room. '
          'All lawyers and interns are expected to attend with case progress updates.',
      authorId: 's1',
      authorName: 'Adv. Rajesh Sharma',
      authorRole: 'Lawyer',
      createdAt: DateTime.now().subtract(const Duration(days: 7)),
      priority: NoticePriority.normal,
      isPinned: true,
    ),
    Notice(
      id: 'n4',
      title: 'Library Resources Updated',
      content:
          'New legal reference books and journals have been added to the office library. '
          'Includes latest amendments to CPC and CrPC. Interns are encouraged to review.',
      authorId: 's2',
      authorName: 'Adv. Priya Patel',
      authorRole: 'Lawyer',
      createdAt: DateTime.now().subtract(const Duration(days: 14)),
      priority: NoticePriority.normal,
      isPinned: false,
    ),
  ];
}
