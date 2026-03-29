import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../main.dart';
import '../widgets/common_widgets.dart';
import '../models/case_model.dart';
import '../providers/providers.dart';
import '../services/hive_service.dart';
import '../services/notification_service.dart';
import '../services/pdf_service.dart';
import '../services/ecourts_import_service.dart';
import '../models/messaging_models.dart';
import 'messenger_screens.dart';
import '../services/sync_service.dart';
import 'calendar_screens.dart';

const _uuid = Uuid();
const int _maxUploadBytes = 25 * 1024 * 1024;

// ==================== LAWYER DASHBOARD ====================
class LawyerDashboard extends ConsumerStatefulWidget {
  const LawyerDashboard({super.key});

  @override
  ConsumerState<LawyerDashboard> createState() => _LawyerDashboardState();
}

class _LawyerDashboardState extends ConsumerState<LawyerDashboard> {
  int _currentNavIndex = 0;
  final Set<String> _seenSosAlertIds = <String>{};
  bool _showSosBlink = false;
  bool _blinkOn = false;
  Timer? _blinkTicker;
  Timer? _blinkStopper;

  void _triggerSosBlink() {
    _blinkTicker?.cancel();
    _blinkStopper?.cancel();

    setState(() {
      _showSosBlink = true;
      _blinkOn = true;
    });

    _blinkTicker = Timer.periodic(const Duration(milliseconds: 220), (_) {
      if (!mounted) return;
      setState(() => _blinkOn = !_blinkOn);
    });

    _blinkStopper = Timer(const Duration(seconds: 3), () {
      _blinkTicker?.cancel();
      if (!mounted) return;
      setState(() {
        _showSosBlink = false;
        _blinkOn = false;
      });
    });
  }

  void _processSosAlerts(
    AsyncValue<List<Map<String, dynamic>>> alertsAsync,
    String currentUid,
  ) {
    alertsAsync.whenData((alerts) {
      for (final alert in alerts) {
        final id = (alert['id'] ?? '').toString();
        if (id.isEmpty || _seenSosAlertIds.contains(id)) continue;

        final timestampRaw = (alert['timestamp'] ?? '').toString();
        final sentAt = DateTime.tryParse(timestampRaw);
        final isRecent = sentAt != null &&
            DateTime.now().difference(sentAt) <= const Duration(minutes: 2);

        _seenSosAlertIds.add(id);

        if (NotificationService.shouldSuppressSosVisual(sosId: id)) {
          continue;
        }

        // Ignore stale SOS alerts to avoid confusion when opening app much later.
        if (!isRecent) continue;

        if ((alert['sentBy'] ?? '').toString() == currentUid) continue;

        _triggerSosBlink();

        if (mounted) {
          final senderName =
              (alert['sentByName'] ?? 'Team member').toString();
          final caseName = (alert['caseName'] ?? 'Unknown case').toString();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('SOS received from $senderName ($caseName)'),
              backgroundColor: AppColors.error,
            ),
          );
        }

        NotificationService.showSOSAlert(
          senderName: (alert['sentByName'] ?? 'Team member').toString(),
          caseName: (alert['caseName'] ?? 'Unknown case').toString(),
          courtRoom: (alert['courtRoom'] ?? 'Unknown courtroom').toString(),
        );
      }
    });
  }

  @override
  void dispose() {
    _blinkTicker?.cancel();
    _blinkStopper?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Trigger background sync on dashboard load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(currentUserProvider);
      if (user != null) {
        SyncService().fullSync();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final sosAlerts = ref.watch(sosAlertsProvider);
    final cases = ref.watch(casesProvider);
    final tasks = ref.watch(tasksProvider);
    final reminders = ref.watch(remindersProvider);
    final assignments = ref.watch(assignmentsProvider);
    final isOnline = ref.watch(connectivityProvider).value ?? true;
    final uid = user?.uid ?? '';

    if (uid.isNotEmpty) {
      _processSosAlerts(sosAlerts, uid);
    }

    final activeCases = cases.where((c) => !c.isClosed).toList();
    final now = DateTime.now();
    final todayCases = cases.where((c) {
      if (c.nextHearingDate == null) return false;
      return c.nextHearingDate!.year == now.year &&
          c.nextHearingDate!.month == now.month &&
          c.nextHearingDate!.day == now.day;
    }).toList();

    final visibleTasks = tasks.where((t) {
      final uid = user?.uid ?? '';
      if (uid.isEmpty) return false;
      final assigned = List<String>.from(t['assignedJuniorIds'] ?? const []);
      final isOwner = t['createdBy'] == uid;
      final isPublic = t['isPublic'] == true || t['visibility'] == 'everyone';
      final isAssigned = assigned.contains(uid);
      return isOwner || isPublic || isAssigned;
    }).toList();

    final pendingTasks =
        visibleTasks.where((t) => t['status'] != 'completed').toList();

    final visibleAssignments = assignments.where((a) {
      final uid = user?.uid ?? '';
      if (uid.isEmpty) return false;
      final assignedToIds = List<String>.from(a['assignedToIds'] ?? const []);
      final participantIds = List<String>.from(a['participantIds'] ?? const []);
      final assignedToId = (a['assignedToId'] ?? '').toString();
      return a['createdBy'] == uid ||
          assignedToIds.contains(uid) ||
          participantIds.contains(uid) ||
          assignedToId == uid;
    }).toList();
    final pendingAssignments =
        visibleAssignments.where((a) => a['status'] != 'completed').toList();

    final todayReminders = reminders.where((r) {
      final d = r.dueDateTime;
      return !r.isCompleted &&
          d.year == now.year &&
          d.month == now.month &&
          d.day == now.day;
    }).toList();

    final todayTaskDeadlines = pendingTasks.where((t) {
      final d = DateTime.tryParse((t['deadline'] ?? '').toString());
      return d != null &&
          d.year == now.year &&
          d.month == now.month &&
          d.day == now.day;
    }).toList();

    final todayAssignmentDeadlines = pendingAssignments.where((a) {
      final d = DateTime.tryParse((a['deadline'] ?? '').toString());
      return d != null &&
          d.year == now.year &&
          d.month == now.month &&
          d.day == now.day;
    }).toList();

    final todayCount = todayCases.length +
        todayReminders.length +
        todayTaskDeadlines.length +
        todayAssignmentDeadlines.length;
    final pendingWorkCount = pendingTasks.length + pendingAssignments.length;

    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Welcome back',
                          style: TextStyle(
                            color: AppColors.white.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                        if (!isOnline) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.error.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.cloud_off,
                                    color: AppColors.error, size: 10),
                                SizedBox(width: 4),
                                Text('Offline',
                                    style: TextStyle(
                                        color: AppColors.error,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      user?.name ?? 'Advocate',
                      style: const TextStyle(
                        color: AppColors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.settings,
                            color: AppColors.white, size: 20),
                        onPressed: () =>
                            Navigator.pushNamed(context, '/settings-lawyer'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.accent, width: 2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: AvatarCircle(
                        initials: user?.initials ?? 'U',
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // 1. Status Summary
                  _buildStatusSummary(
                    todayCount: todayCount,
                    pendingWork: pendingWorkCount,
                    activeCount: activeCases.length,
                  ),
                  const SizedBox(height: 24),

                  // 2. Today's Schedule
                  _buildTodaySchedule(
                    todayCases,
                    pendingTasks,
                    pendingAssignments,
                    todayReminders,
                  ),
                  const SizedBox(height: 24),

                  // 3. Active Cases
                  SectionHeader(
                    title: 'Active Cases',
                    actionText: 'View All',
                    onActionTap: () =>
                        Navigator.pushNamed(context, '/case-list'),
                  ),
                  const SizedBox(height: 12),
                  if (activeCases.isEmpty)
                    AppCard(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Icon(Icons.folder_open,
                                size: 48, color: Colors.grey[300]),
                            const SizedBox(height: 12),
                            Text('No active cases yet',
                                style: TextStyle(color: Colors.grey[500])),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: () => Navigator.pushNamed(
                                  context, '/ecourts-import'),
                              icon: const Icon(Icons.cloud_download, size: 16),
                              label: const Text('Import from eCourts'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ...activeCases.take(3).map((c) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildCaseCard(
                            caseModel: c,
                            onTap: () => Navigator.pushNamed(
                                context, '/case-detail',
                                arguments: c),
                          ),
                        )),
                  const SizedBox(height: 24),

                  // 4. Quick Tools
                  _buildQuickTools(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
            ],
          ),
          if (_showSosBlink)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  color: _blinkOn
                      ? AppColors.error.withOpacity(0.32)
                      : Colors.transparent,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: BottomNavBar(
        currentIndex: _currentNavIndex,
        items: const [
          BottomNavItem(icon: Icons.home, label: 'Home'),
          BottomNavItem(icon: Icons.work, label: 'Work'),
          BottomNavItem(icon: Icons.folder, label: 'Cases'),
          BottomNavItem(icon: Icons.calendar_today, label: 'Calendar'),
          BottomNavItem(icon: Icons.message, label: 'Messages'),
        ],
        onTap: (index) {
          setState(() => _currentNavIndex = index);
          if (index == 1) Navigator.pushNamed(context, '/lawyer-work');
          if (index == 2) Navigator.pushNamed(context, '/case-list');
          if (index == 3) Navigator.pushNamed(context, '/personal-calendar');
          if (index == 4) Navigator.pushNamed(context, '/messages');
        },
      ),
    );
  }

  Widget _buildStatusSummary({
    required int todayCount,
    required int pendingWork,
    required int activeCount,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummaryCard(
              "Today's Schedule", '$todayCount', AppColors.primary),
          const SizedBox(width: 12),
          _buildSummaryCard("Pending Work", '$pendingWork', AppColors.accent),
          const SizedBox(width: 12),
          _buildSummaryCard(
              'Active Cases', '$activeCount', AppColors.secondary),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(String label, String count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              count,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.text,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTodaySchedule(
    List<CaseModel> todayCases,
    List<Map<String, dynamic>> pendingTasks,
    List<Map<String, dynamic>> pendingAssignments,
    List<dynamic> todayReminders,
  ) {
    final List<Map<String, dynamic>> events = [];

    // Add today's hearings
    for (final c in todayCases) {
      events.add({
        'title': 'Hearing: ${c.title}',
        'time': c.courtRoom,
        'type': 'Hearing',
        'color': AppColors.hearingBlue,
      });
    }

    // Add urgent tasks due today
    final now = DateTime.now();
    for (final t in pendingTasks) {
      final deadline = DateTime.tryParse(t['deadline'] ?? '');
      if (deadline != null &&
          deadline.year == now.year &&
          deadline.month == now.month &&
          deadline.day == now.day) {
        events.add({
          'title': 'Deadline: ${t['title']}',
          'time': DateFormat('h:mm a').format(deadline),
          'type': 'Deadline',
          'color': AppColors.deadlineRed,
        });
      }
    }

    // Add assignment deadlines due today
    for (final a in pendingAssignments) {
      final deadline = DateTime.tryParse((a['deadline'] ?? '').toString());
      if (deadline != null &&
          deadline.year == now.year &&
          deadline.month == now.month &&
          deadline.day == now.day) {
        events.add({
          'title': 'Assignment: ${a['title'] ?? 'Untitled'}',
          'time': DateFormat('h:mm a').format(deadline),
          'type': 'Assignment',
          'color': AppColors.secondary,
        });
      }
    }

    // Add reminders scheduled for today
    for (final r in todayReminders) {
      events.add({
        'title': 'Reminder: ${r.title}',
        'time': DateFormat('h:mm a').format(r.dueDateTime),
        'type': 'Reminder',
        'color': r.getUrgencyColor(),
      });
    }

    // Fallback mock if no real events
    if (events.isEmpty) {
      events.addAll([
        {
          'title': 'No events today',
          'time': 'Tap Calendar to add',
          'type': 'Info',
          'color': AppColors.grey,
        },
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Today's Schedule",
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 110,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: events.length,
            itemBuilder: (context, index) {
              final event = events[index];
              return Container(
                width: 200,
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (event['color'] as Color).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: (event['color'] as Color).withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      event['time'] as String,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: event['color'] as Color,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      event['title'] as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildQuickTools() {
    final List<Map<String, Object>> tools = [
      {
        'icon': Icons.cloud_download,
        'label': 'Import eCourts',
        'color': Colors.teal,
        'route': '/ecourts-import'
      },
      {
        'icon': Icons.notifications,
        'label': 'Notices',
        'color': AppColors.secondary,
        'route': '/notices'
      },
      {
        'icon': Icons.description,
        'label': 'Doc Generator',
        'color': AppColors.accent,
        'route': '/document-generator'
      },
      {
        'icon': Icons.sos,
        'label': 'SOS',
        'color': AppColors.error,
        'route': '/courtroom-sos'
      },
      {
        'icon': Icons.task_alt,
        'label': 'Tasks',
        'color': Colors.green,
        'route': '/lawyer-work',
        'tabIndex': 0,
      },
      {
        'icon': Icons.assignment,
        'label': 'Assignment',
        'color': Colors.purple,
        'route': '/lawyer-work',
        'tabIndex': 1,
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Tools',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
          ),
          itemCount: tools.length,
          itemBuilder: (context, index) {
            final tool = tools[index];
            final route = tool['route'] as String;
            final tabIndex = tool['tabIndex'] as int?;
            return _buildQuickToolButton(
              tool['icon'] as IconData,
              tool['label'] as String,
              tool['color'] as Color,
              () => Navigator.pushNamed(
                context,
                route,
                arguments: tabIndex == null ? null : {'tabIndex': tabIndex},
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildQuickToolButton(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 19),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.text,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaseCard({
    required CaseModel caseModel,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    caseModel.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: caseModel.isClosed
                        ? const Color(0xFFFFF9E6)
                        : const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    caseModel.statusText,
                    style: TextStyle(
                      color: caseModel.isClosed
                          ? const Color(0xFF9E9E9E)
                          : const Color(0xFF4CAF50),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${caseModel.courtComplex} • ${caseModel.caseType}',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: caseModel.urgencyColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.calendar_today,
                        size: 12, color: AppColors.accent),
                    const SizedBox(width: 4),
                    Text(
                      caseModel.nextHearingDate != null
                          ? 'Hearing: ${DateFormat('MMM d').format(caseModel.nextHearingDate!)}'
                          : caseModel.isClosed
                              ? 'Closed'
                              : 'No date set',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.accent),
                    ),
                  ],
                ),
                Icon(Icons.chevron_right, color: Colors.grey[300]),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showManageMembersDialog(BuildContext context, CaseModel c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _ManageCaseMembersSheet(caseModel: c);
      },
    );
  }
}

class _ManageCaseMembersSheet extends ConsumerStatefulWidget {
  final CaseModel caseModel;

  const _ManageCaseMembersSheet({required this.caseModel});

  @override
  ConsumerState<_ManageCaseMembersSheet> createState() =>
      _ManageCaseMembersSheetState();
}

class _ManageCaseMembersSheetState
    extends ConsumerState<_ManageCaseMembersSheet> {
  late List<String> _selectedMemberIds;

  @override
  void initState() {
    super.initState();
    _selectedMemberIds = List.from(widget.caseModel.assignedMemberIds);
  }

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(firmMembersProvider);
    final user = ref.read(currentUserProvider);

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20), topRight: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Manage Team',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.text)),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: membersAsync.when(
              data: (members) {
                final validMembers = members
                    .where((m) => m.role != 'client' && m.uid != user?.uid)
                    .toList();

                if (validMembers.isEmpty) {
                  return const Center(child: Text('No firm members found.'));
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: validMembers.length,
                  itemBuilder: (context, index) {
                    final m = validMembers[index];
                    final isSelected = _selectedMemberIds.contains(m.uid);

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedMemberIds.remove(m.uid);
                          } else {
                            _selectedMemberIds.add(m.uid);
                          }
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.accent.withOpacity(0.1)
                              : AppColors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: isSelected
                                  ? AppColors.accent
                                  : Colors.grey[300]!,
                              width: 2),
                        ),
                        child: Row(
                          children: [
                            AvatarCircle(initials: m.initials, size: 40),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.name,
                                      style: TextStyle(
                                          fontWeight: isSelected
                                              ? FontWeight.w600
                                              : FontWeight.w500)),
                                  Text(m.role,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[600])),
                                ],
                              ),
                            ),
                            if (isSelected)
                              const Icon(Icons.check_circle,
                                  color: AppColors.accent),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            color: AppColors.white,
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  // Ensure current user is always in the list if they are a lawyer/intern
                  if (user != null &&
                      user.role != 'client' &&
                      !_selectedMemberIds.contains(user.uid)) {
                    _selectedMemberIds.add(user.uid);
                  }

                  ref
                      .read(casesProvider.notifier)
                      .updateCase(widget.caseModel.cino, {
                    // Updating both for backward compatibility
                    'assignedLawyerIds': _selectedMemberIds,
                    'assignedInternIds': [],
                  });
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Team updated!')));
                },
                child: const Text('Save Team',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== CASE LIST ====================
class CaseListScreen extends ConsumerStatefulWidget {
  const CaseListScreen({super.key});

  @override
  ConsumerState<CaseListScreen> createState() => _CaseListScreenState();
}

class _CaseListScreenState extends ConsumerState<CaseListScreen> {
  String _searchQuery = '';
  String _filter = 'All'; // All, Active, Closed

  static const TextStyle _caseControlTextPrimary = TextStyle(
    color: AppColors.primary,
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle _caseControlTextWhite = TextStyle(
    color: AppColors.white,
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );

  Future<void> _confirmDeleteCase(CaseModel c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Case'),
        content: Text(
            'Delete "${c.title}"? This will remove it from your app and Firebase sync queue.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    await ref.read(casesProvider.notifier).deleteCase(c.cino);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Case "${c.title}" deleted'),
          backgroundColor: AppColors.error),
    );
  }

  Future<void> _confirmClearImportedCases() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Imported Source'),
        content: const Text(
            'This will clear eCourts import linkage for imported cases. Team members and uploaded documents will be preserved.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear Imports',
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final deletedCount = await EcourtsImportService.clearImportedCases();
    if (!mounted) return;
    ref.read(casesProvider.notifier).refresh();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Processed $deletedCount imported case(s). Metadata preserved where present.')),
    );
  }

  Future<void> _showManualCaseDialog() async {
    final titleCtrl = TextEditingController();
    final petitionerCtrl = TextEditingController();
    final respondentCtrl = TextEditingController();
    final caseNumberCtrl = TextEditingController();
    final cinoCtrl = TextEditingController();
    final caseTypeCtrl = TextEditingController(text: 'Civil');
    final courtComplexCtrl = TextEditingController();
    final courtRoomCtrl = TextEditingController();
    final districtCtrl = TextEditingController();
    final stateCtrl = TextEditingController();
    DateTime? hearingDate;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Add Manual Case'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                      controller: titleCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Case Title *')),
                  TextField(
                      controller: caseNumberCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Case Number *')),
                  TextField(
                      controller: cinoCtrl,
                      decoration:
                          const InputDecoration(labelText: 'CINO (Optional)')),
                  TextField(
                      controller: petitionerCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Petitioner')),
                  TextField(
                      controller: respondentCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Respondent')),
                  TextField(
                      controller: caseTypeCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Case Type')),
                  TextField(
                      controller: courtComplexCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Court Complex')),
                  TextField(
                      controller: courtRoomCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Court Room')),
                  TextField(
                      controller: districtCtrl,
                      decoration: const InputDecoration(labelText: 'District')),
                  TextField(
                      controller: stateCtrl,
                      decoration: const InputDecoration(labelText: 'State')),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          hearingDate == null
                              ? 'No hearing date'
                              : 'Hearing: ${DateFormat('dd MMM yyyy').format(hearingDate!)}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          final selected = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (selected != null) {
                            setDialogState(() => hearingDate = selected);
                          }
                        },
                        child: const Text('Set Date'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  final title = titleCtrl.text.trim();
                  final caseNumber = caseNumberCtrl.text.trim();
                  if (title.isEmpty || caseNumber.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Title and case number are required')),
                    );
                    return;
                  }

                  final rawCino = cinoCtrl.text.trim();
                  final cino = rawCino.isEmpty
                      ? 'MANUAL_${DateTime.now().millisecondsSinceEpoch}'
                      : rawCino;

                  final model = CaseModel(
                    cino: cino,
                    title: title,
                    petitioner: petitionerCtrl.text.trim().isEmpty
                        ? 'Petitioner'
                        : petitionerCtrl.text.trim(),
                    respondent: respondentCtrl.text.trim().isEmpty
                        ? 'Respondent'
                        : respondentCtrl.text.trim(),
                    caseNumber: caseNumber,
                    caseType: caseTypeCtrl.text.trim().isEmpty
                        ? 'General'
                        : caseTypeCtrl.text.trim(),
                    year: DateTime.now().year,
                    courtComplex: courtComplexCtrl.text.trim(),
                    courtRoom: courtRoomCtrl.text.trim(),
                    district: districtCtrl.text.trim().isEmpty
                        ? 'Unknown'
                        : districtCtrl.text.trim(),
                    state: stateCtrl.text.trim().isEmpty
                        ? 'Unknown'
                        : stateCtrl.text.trim(),
                    nextHearingDate: hearingDate,
                    lastHearingDate: null,
                    currentStage: 'New',
                    decisionDate: null,
                    disposalStatus: null,
                    isClosed: false,
                    urgencyLevel: CaseModel.computeUrgency(hearingDate),
                    assignedMemberIds: const [],
                    clientIds: const [],
                  );

                  await ref.read(casesProvider.notifier).addCase(model);
                  if (!mounted) return;
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Manual case added successfully')),
                  );
                },
                child: const Text('Add Case'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);
    final isInternUser = currentUser?.role == 'intern';
    final allCases = ref.watch(casesProvider);
    final visibleCases = isInternUser
        ? allCases
            .where((c) => c.assignedMemberIds.contains(currentUser?.uid))
            .toList()
        : allCases;

    var filtered = visibleCases.where((c) {
      if (_filter == 'Active') return !c.isClosed;
      if (_filter == 'Closed') return c.isClosed;
      return true;
    }).toList();

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered
          .where((c) =>
              c.title.toLowerCase().contains(q) ||
              c.petitioner.toLowerCase().contains(q) ||
              c.respondent.toLowerCase().contains(q) ||
              c.caseNumber.toLowerCase().contains(q) ||
              c.courtComplex.toLowerCase().contains(q) ||
              c.caseType.toLowerCase().contains(q))
          .toList();
    }

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Column(
              children: [
                Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'All Cases (${visibleCases.length})',
                        style: const TextStyle(
                          color: AppColors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (!isInternUser) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      GestureDetector(
                        onTap: () =>
                            Navigator.pushNamed(context, '/ecourts-import'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.cloud_download,
                                  color: AppColors.primary, size: 14),
                              SizedBox(width: 4),
                              Text('Import', style: _caseControlTextPrimary),
                            ],
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _showManualCaseDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.white.withOpacity(0.3)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add, color: AppColors.white, size: 14),
                              SizedBox(width: 4),
                              Text('Manual', style: _caseControlTextWhite),
                            ],
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon:
                            const Icon(Icons.more_vert, color: AppColors.white),
                        onSelected: (value) {
                          if (value == 'clear_imports') {
                            _confirmClearImportedCases();
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem<String>(
                            value: 'clear_imports',
                            child: Row(
                              children: [
                                Icon(Icons.delete_sweep,
                                    color: AppColors.error),
                                SizedBox(width: 8),
                                Text('Delete Imported Cases'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                SearchField(
                  hint: 'Search cases...',
                  onChanged: (q) => setState(() => _searchQuery = q),
                ),
                const SizedBox(height: 12),
                Row(
                  children: ['All', 'Active', 'Closed']
                      .map((f) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _filterChip(f),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off,
                            size: 64, color: Colors.grey[300]),
                        const SizedBox(height: 16),
                        Text(
                          visibleCases.isEmpty
                              ? isInternUser
                                  ? 'No cases assigned yet.\nA lawyer needs to add you to a case team.'
                                  : 'No cases yet.\nImport from eCourts or add a manual case.'
                              : 'No cases match your search.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final c = filtered[index];
                      return _buildCaseItem(
                        context,
                        c,
                        allowDelete: !isInternUser,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label) {
    final isSelected = _filter == label;
    return GestureDetector(
      onTap: () => setState(() => _filter = label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color:
              isSelected ? AppColors.accent : AppColors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isSelected
                ? AppColors.primary
                : AppColors.white.withOpacity(0.7),
          ),
        ),
      ),
    );
  }

  Widget _buildCaseItem(BuildContext context, CaseModel c,
      {required bool allowDelete}) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/case-detail', arguments: c),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (c.urgencyLevel == 'red' && !c.isClosed) ...[
                    const Icon(Icons.local_fire_department,
                        color: AppColors.error, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      c.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (allowDelete)
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: AppColors.error, size: 18),
                      tooltip: 'Delete case',
                      onPressed: () => _confirmDeleteCase(c),
                    ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.isClosed
                          ? const Color(0xFFFFF9E6)
                          : const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      c.statusText,
                      style: TextStyle(
                        color: c.isClosed
                            ? const Color(0xFF9E9E9E)
                            : const Color(0xFF4CAF50),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.person_outline,
                      size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${c.courtComplex} • ${c.district}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      c.caseType,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.urgencyColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c.nextHearingDate != null
                          ? 'Next: ${DateFormat('MMM d, yyyy').format(c.nextHearingDate!)}'
                          : c.isClosed
                              ? (c.disposalStatus ?? 'Closed')
                              : 'No date',
                      style: TextStyle(
                        fontSize: 12,
                        color: c.urgencyColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (c.currentStage.isNotEmpty)
                    Flexible(
                      child: Text(
                        c.currentStage,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey[400]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== CASE DETAIL ====================
class CaseDetailScreen extends ConsumerStatefulWidget {
  const CaseDetailScreen({super.key});

  @override
  ConsumerState<CaseDetailScreen> createState() => _CaseDetailScreenState();
}

class _CaseDetailScreenState extends ConsumerState<CaseDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  CaseModel? _caseModel;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is CaseModel) {
      _caseModel = args;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If no argument passed, use first case from provider
    final cases = ref.watch(casesProvider);
    final c = _caseModel ?? (cases.isNotEmpty ? cases.first : null);

    if (c == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('No case selected'),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    final tasks = ref.watch(tasksProvider);
    final caseTasks = tasks.where((t) => t['caseId'] == c.cino).toList();

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
            color: AppColors.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        _buildBackButton(context),
                        const SizedBox(width: 12),
                        Text(
                          'Case Details',
                          style: TextStyle(
                              color: AppColors.white.withOpacity(0.6),
                              fontSize: 14),
                        ),
                      ],
                    ),
                    if (!c.isClosed)
                      IconButton(
                        onPressed: () => Navigator.pushNamed(
                            context, '/courtroom-sos',
                            arguments: c),
                        icon: const Icon(Icons.sos, color: AppColors.error),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.error.withOpacity(0.15),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  c.title,
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${c.courtComplex} • ${c.caseNumber}',
                  style: TextStyle(
                      color: AppColors.white.withOpacity(0.6), fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        c.isClosed
                            ? 'Closed - ${c.disposalStatus ?? 'Disposed'}'
                            : 'Active - ${c.currentStage}',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: c.urgencyColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            color: AppColors.white,
            child: TabBar(
              controller: _tabController,
              labelColor: AppColors.accent,
              unselectedLabelColor: Colors.grey[400],
              indicatorColor: AppColors.accent,
              indicatorWeight: 3,
              tabs: const [
                Tab(text: 'Details'),
                Tab(text: 'Tasks'),
                Tab(text: 'Dates'),
                Tab(text: 'Docs'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildDetailsTab(c),
                _buildTasksTab(caseTasks, c),
                _buildDatesTab(c),
                _buildDocumentsTab(c),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: !c.isClosed
          ? FloatingActionButton(
              onPressed: () => _showAddOptions(c),
              backgroundColor: AppColors.accent,
              child: const Icon(Icons.add, color: AppColors.primary),
            )
          : null,
    );
  }

  Widget _buildDetailsTab(CaseModel c) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          AppCard(
            child: Column(
              children: [
                _detailRow('Case Number', c.caseNumber),
                const Divider(height: 24),
                _detailRow('Case Type', c.caseType),
                const Divider(height: 24),
                _detailRow('Petitioner', c.petitioner),
                const Divider(height: 24),
                _detailRow('Respondent', c.respondent),
                const Divider(height: 24),
                _detailRow('Court', c.courtComplex),
                const Divider(height: 24),
                _detailRow('Court Room', c.courtRoom),
                const Divider(height: 24),
                _detailRow('District', '${c.district}, ${c.state}'),
                const Divider(height: 24),
                _detailRow('Current Stage', c.currentStage),
                if (c.nextHearingDate != null) ...[
                  const Divider(height: 24),
                  _detailRow('Next Hearing',
                      DateFormat('dd MMM yyyy').format(c.nextHearingDate!)),
                ],
                if (c.lastHearingDate != null) ...[
                  const Divider(height: 24),
                  _detailRow('Last Hearing',
                      DateFormat('dd MMM yyyy').format(c.lastHearingDate!)),
                ],
                if (c.decisionDate != null) ...[
                  const Divider(height: 24),
                  _detailRow('Decision Date',
                      DateFormat('dd MMM yyyy').format(c.decisionDate!)),
                ],
                if (c.disposalStatus != null &&
                    c.disposalStatus!.isNotEmpty) ...[
                  const Divider(height: 24),
                  _detailRow('Disposal', c.disposalStatus!),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (c.assignedMemberIds.isNotEmpty) ...[
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Assigned Team',
                          style:
                              TextStyle(fontSize: 13, color: Colors.grey[600])),
                      if (!c.isClosed)
                        TextButton.icon(
                          onPressed: () => _showManageMembersDialog(context, c),
                          icon: const Icon(Icons.group_add, size: 16),
                          label: const Text('Manage Team',
                              style: TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 0),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ref.watch(firmMembersProvider).when(
                        data: (members) {
                          final assigned = members
                              .where((m) => c.assignedMemberIds.contains(m.uid))
                              .toList();
                          if (assigned.isEmpty) return const SizedBox.shrink();
                          return Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: assigned.map((m) {
                              return Tooltip(
                                message: m.name,
                                child: CircleAvatar(
                                  radius: 16,
                                  backgroundColor: AppColors.primary,
                                  child: Text(m.initials,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.white,
                                          fontWeight: FontWeight.bold)),
                                ),
                              );
                            }).toList(),
                          );
                        },
                        loading: () => const SizedBox(
                            height: 32,
                            width: 32,
                            child: CircularProgressIndicator()),
                        error: (_, __) => const SizedBox.shrink(),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (!c.isClosed)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.secondary.withOpacity(0.1),
                    foregroundColor: AppColors.secondary,
                    elevation: 0,
                  ),
                  onPressed: () => _createCaseChat(context, c),
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: const Text('Open Case Chat'),
                ),
              ),
            const SizedBox(height: 12),
            if (c.assignedMemberIds.isNotEmpty && !c.isClosed)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent.withOpacity(0.1),
                    foregroundColor: AppColors.primary,
                    elevation: 0,
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CreateReminderScreen(
                          initialMemberIds: c.assignedMemberIds.toSet()
                            ..add(ref.read(currentUserProvider)?.uid ?? ''),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.event_available, size: 18),
                  label: const Text('New Case Reminder'),
                ),
              ),
            const SizedBox(height: 16),
          ],
          // Generate Document button
          if (!c.isClosed)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pushNamed(
                    context, '/document-generator',
                    arguments: c),
                icon: const Icon(Icons.description, size: 18),
                label: const Text('Generate Document'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTasksTab(List<Map<String, dynamic>> caseTasks, CaseModel c) {
    final currentUser = ref.watch(currentUserProvider);
    final isInternUser = currentUser?.role == 'intern';

    if (caseTasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.task_alt, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text('No tasks for this case',
                style: TextStyle(color: Colors.grey[500])),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: caseTasks.length,
      itemBuilder: (context, index) {
        final task = caseTasks[index];
        final isCompleted = task['status'] == 'completed';
        final isEscalated = task['isEscalated'] == true;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: AppCard(
            borderColor: isEscalated ? AppColors.error : null,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    ref.read(tasksProvider.notifier).updateTask(task['id'], {
                      'status': isCompleted ? 'pending' : 'completed',
                    });
                  },
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: isCompleted ? AppColors.success : AppColors.white,
                      border: Border.all(
                        color:
                            isCompleted ? AppColors.success : AppColors.accent,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: isCompleted
                        ? const Icon(Icons.check,
                            color: AppColors.white, size: 14)
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (isEscalated)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: Icon(Icons.warning,
                                  color: AppColors.error, size: 14),
                            ),
                          Expanded(
                            child: Text(
                              task['title'] ?? '',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: isCompleted
                                    ? Colors.grey[400]
                                    : AppColors.text,
                                decoration: isCompleted
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        task['deadline'] != null
                            ? 'Due: ${DateFormat('MMM d').format(DateTime.parse(task['deadline']))}'
                            : '',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      _showEditCaseTaskDialog(task);
                      return;
                    }
                    if (value == 'status_pending') {
                      ref.read(tasksProvider.notifier).updateTask(task['id'], {
                        'status': 'pending',
                      });
                      return;
                    }
                    if (value == 'status_inProgress') {
                      ref.read(tasksProvider.notifier).updateTask(task['id'], {
                        'status': 'inProgress',
                      });
                      return;
                    }
                    if (value == 'status_completed') {
                      ref.read(tasksProvider.notifier).updateTask(task['id'], {
                        'status': 'completed',
                      });
                      return;
                    }
                    if (value == 'delete') {
                      if (isInternUser) return;
                      ref.read(tasksProvider.notifier).deleteTask(task['id']);
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem<String>(
                      value: 'edit',
                      child: Text('Edit Task'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'status_pending',
                      child: Text('Mark Pending'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'status_inProgress',
                      child: Text('Mark In Progress'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'status_completed',
                      child: Text('Mark Completed'),
                    ),
                    if (!isInternUser)
                      const PopupMenuItem<String>(
                        value: 'delete',
                        child: Text('Delete Task'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEditCaseTaskDialog(Map<String, dynamic> task) async {
    final titleController = TextEditingController(text: task['title'] ?? '');
    final descriptionController =
        TextEditingController(text: task['description'] ?? '');
    DateTime selectedDeadline = task['deadline'] != null
        ? DateTime.tryParse(task['deadline']) ?? DateTime.now()
        : DateTime.now();

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Edit Task'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descriptionController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Description'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: selectedDeadline,
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 3650)),
                      );
                      if (picked != null) {
                        setDialogState(() => selectedDeadline = picked);
                      }
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                        'Deadline: ${DateFormat('dd/MM/yyyy').format(selectedDeadline)}'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );

    if (shouldSave != true) return;
    if (titleController.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task title cannot be empty')),
      );
      return;
    }

    await ref.read(tasksProvider.notifier).updateTask(task['id'], {
      'title': titleController.text.trim(),
      'description': descriptionController.text.trim(),
      'deadline': selectedDeadline.toIso8601String(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Task updated successfully')),
    );
  }

  Widget _buildDatesTab(CaseModel c) {
    final List<Map<String, dynamic>> dates = [];
    if (c.nextHearingDate != null) {
      dates.add({
        'date': c.nextHearingDate!,
        'title': 'Next Hearing',
        'location': c.courtComplex,
        'stage': c.currentStage,
      });
    }
    if (c.lastHearingDate != null) {
      dates.add({
        'date': c.lastHearingDate!,
        'title': 'Previous Hearing',
        'location': c.courtComplex,
        'stage': 'Completed',
      });
    }
    if (c.decisionDate != null) {
      dates.add({
        'date': c.decisionDate!,
        'title': 'Decision',
        'location': c.courtComplex,
        'stage': c.disposalStatus ?? 'Decided',
      });
    }

    if (dates.isEmpty) {
      return const Center(child: Text('No dates available'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: dates.length,
      itemBuilder: (context, index) {
        final d = dates[index];
        final date = d['date'] as DateTime;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: AppCard(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Text('${date.day}',
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.accent)),
                      Text(DateFormat('MMM').format(date),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.accent)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d['title'],
                          style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              color: AppColors.text)),
                      Text(d['location'],
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[500])),
                      Text(d['stage'],
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.secondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDocumentsTab(CaseModel c) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Quick generate buttons
          if (!c.isClosed) ...[
            Row(
              children: [
                Expanded(
                  child: _docButton(
                    'Exemption\nApplication',
                    Icons.description,
                    Colors.blue,
                    () => _generateDoc(c, 'exemption'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _docButton(
                    'Adjournment\nApplication',
                    Icons.schedule,
                    Colors.orange,
                    () => _generateDoc(c, 'adjournment'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          if (c.customDocuments.isEmpty)
            Center(
              child: Text(
                'Documents will appear here\nafter generation or upload.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            )
          else
            Column(
              children: c.customDocuments.map((doc) {
                final isPdf = doc['type'] == 'pdf';
                final isDoc = doc['type'] == 'doc';

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: AppCard(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (isPdf
                                    ? Colors.red
                                    : isDoc
                                        ? Colors.blue
                                        : Colors.green)
                                .withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            isPdf
                                ? Icons.picture_as_pdf
                                : isDoc
                                    ? Icons.description
                                    : Icons.image,
                            color: isPdf
                                ? Colors.red
                                : isDoc
                                    ? Colors.blue
                                    : Colors.green,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(doc['name'] ?? 'Document',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(
                                  'Uploaded on ${DateFormat('MMM d, yyyy').format(DateTime.parse(doc['uploadedAt']))}',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey[600])),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.download,
                              color: AppColors.primary),
                          onPressed: () async {
                            final rawUrl = (doc['url'] as String? ?? '').trim();
                            final uri = Uri.tryParse(rawUrl);
                            if (uri == null) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Invalid document URL.')),
                              );
                              return;
                            }
                            final opened = await launchUrl(uri,
                                mode: LaunchMode.platformDefault);
                            if (!opened && mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Could not open document.')),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),

          const SizedBox(height: 20),
          if (!c.isClosed)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: () => _showUploadDocumentSheet(context, c),
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload Document',
                    style: TextStyle(fontSize: 16)),
              ),
            ),
        ],
      ),
    );
  }

  void _showManageMembersDialog(BuildContext context, CaseModel c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _ManageCaseMembersSheet(caseModel: c);
      },
    );
  }

  void _showUploadDocumentSheet(BuildContext context, CaseModel c) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
                title: const Text('Upload PDF'),
                onTap: () async {
                  Navigator.pop(context);
                  await _pickAndUploadCaseDocument(c, const ['pdf'], 'pdf');
                },
              ),
              ListTile(
                leading: const Icon(Icons.description, color: Colors.blue),
                title: const Text('Upload Word Document'),
                onTap: () async {
                  Navigator.pop(context);
                  await _pickAndUploadCaseDocument(
                      c, const ['doc', 'docx'], 'doc');
                },
              ),
              ListTile(
                leading: const Icon(Icons.image, color: Colors.green),
                title: const Text('Upload Image'),
                onTap: () async {
                  Navigator.pop(context);
                  await _pickAndUploadCaseDocument(
                    c,
                    const ['jpg', 'jpeg', 'png', 'webp'],
                    'image',
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickAndUploadCaseDocument(
    CaseModel c,
    List<String> allowedExtensions,
    String type,
  ) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: false,
        allowedExtensions: allowedExtensions,
        withData: true,
      );

      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.first;
      if (file.bytes == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read selected file.')),
        );
        return;
      }
      if (file.size > _maxUploadBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File is too large. Maximum allowed size is 25 MB.'),
          ),
        );
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uploading document...')),
      );

      final safeName = file.name.replaceAll(' ', '_');
      final refStorage = FirebaseStorage.instance.ref(
          'case_documents/${c.cino}/${DateTime.now().millisecondsSinceEpoch}_$safeName');

      await refStorage.putData(
        file.bytes!,
        SettableMetadata(
          contentType: type == 'pdf'
              ? 'application/pdf'
              : type == 'image'
                  ? 'image/*'
                  : 'application/octet-stream',
        ),
      );

      final url = await refStorage.getDownloadURL();
      final cases = ref.read(casesProvider);
      final latest = cases.where((cc) => cc.cino == c.cino).firstOrNull ?? c;
      final updatedDocs =
          List<Map<String, dynamic>>.from(latest.customDocuments)
            ..add({
              'id': DateTime.now().millisecondsSinceEpoch.toString(),
              'name': file.name,
              'type': type,
              'url': url,
              'size': file.size,
              'uploadedAt': DateTime.now().toIso8601String(),
            });

      await ref.read(casesProvider.notifier).updateCase(c.cino, {
        'customDocuments': updatedDocs,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uploaded ${file.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      final err = e.toString();
      if (kIsWeb && (err.contains('CORS') || err.contains('preflight'))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Upload blocked by Firebase Storage CORS. Configure bucket CORS for localhost and try again.'),
          ),
        );
        return;
      }
      if (err.contains('403') ||
          err.toLowerCase().contains('forbidden') ||
          err.toLowerCase().contains('permission')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Upload blocked by Firebase Storage Rules (403). Allow authenticated write access to case_documents/* in Firebase Storage Rules.'),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    }
  }

  void _createCaseChat(BuildContext context, CaseModel c) {
    final user = ref.read(currentUserProvider);
    final membersAsync = ref.read(firmMembersProvider);
    final allMembers = membersAsync.valueOrNull ?? [];

    final memberIds = <String>{...c.assignedMemberIds, user?.uid ?? ''}
      ..removeWhere((e) => e.trim().isEmpty);

    final memberNames = <String>[];
    for (final id in memberIds) {
      final match = allMembers.where((m) => m.uid == id);
      if (match.isNotEmpty) {
        memberNames.add(match.first.name);
      } else if (id == user?.uid) {
        memberNames.add(user?.name ?? 'Member');
      } else {
        memberNames.add('Member');
      }
    }

    final sanitizedCino = c.cino.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final caseChatId = 'case_chat_$sanitizedCino';

    final existingChat = ref.read(chatGroupsProvider).where((g) {
      final byCaseId = (g.caseId ?? '').trim() == c.cino;
      final byId = g.id == caseChatId;
      final description = (g.description ?? '').toLowerCase();
      final cino = c.cino.toLowerCase();
      final byDescription =
          description.contains('case chat:') && description.contains(cino);
      return byCaseId || byId || byDescription;
    }).firstOrNull;

    if (existingChat != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatConversationScreen(chatGroup: existingChat),
        ),
      );
      return;
    }

    final newChatId = caseChatId;
    final newChat = ChatGroup(
      id: newChatId,
      caseId: c.cino,
      name: c.title,
      description: 'Case Chat: ${c.cino}',
      memberIds: memberIds.toList(),
      memberNames: memberNames,
      createdAt: DateTime.now(),
      createdBy: user?.uid ?? '',
      createdByName: user?.name ?? 'Member',
      lastMessageTime: DateTime.now(),
    );

    ref.read(chatGroupsProvider.notifier).addChatGroup(newChat);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatConversationScreen(chatGroup: newChat),
      ),
    );
  }

  Widget _docButton(
      String label, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AppCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.text),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _generateDoc(CaseModel c, String type) async {
    final user = ref.read(currentUserProvider);
    try {
      late final bytes;
      late final title;
      if (type == 'exemption') {
        bytes = await PdfService.generateExemptionApplication(
          caseData: c,
          reason: 'Illness',
          lawyerName: user?.name ?? 'Advocate',
        );
        title = 'Exemption_Application_${c.caseNumber}';
      } else {
        bytes = await PdfService.generateAdjournmentApplication(
          caseData: c,
          reason: 'Counsel engaged in another court',
          lawyerName: user?.name ?? 'Advocate',
        );
        title = 'Adjournment_Application_${c.caseNumber}';
      }

      await PdfService.previewPdf(bytes, title);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating document: $e')),
        );
      }
    }
  }

  void _showManageTeamSheet(CaseModel c) {
    List<String> selectedIds = List.from(c.assignedMemberIds);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setStateSheet) {
            final membersAsync = ref.watch(firmMembersProvider);
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Manage Case Team',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: AppColors.text),
                      ),
                      const SizedBox(height: 16),
                      membersAsync.when(
                        data: (members) {
                          if (members.isEmpty) {
                            return const Center(
                                child: Text('No firm members found'));
                          }
                          final existing = members
                              .where((m) => selectedIds.contains(m.uid))
                              .toList();
                          return Flexible(
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    existing.isEmpty
                                        ? 'Current team: none'
                                        : 'Current team: ${existing.map((m) => m.name).join(', ')}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[700],
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  MemberSelector(
                                    members: members,
                                    selectedIds: selectedIds,
                                    currentUserId:
                                        ref.read(currentUserProvider)?.uid,
                                    onChanged: (ids) {
                                      setStateSheet(() => selectedIds = ids);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                        loading: () => const CircularProgressIndicator(),
                        error: (err, _) => Text('Error loading members: $err'),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            ref
                                .read(casesProvider.notifier)
                                .updateCase(c.cino, {
                              'assignedLawyerIds':
                                  selectedIds, // Keep old map key for backward compatibility
                              'assignedInternIds': [],
                            });
                            Navigator.pop(context);
                            ScaffoldMessenger.of(this.context).showSnackBar(
                              const SnackBar(
                                  content: Text('Team updated successfully')),
                            );
                          },
                          child: const Text('Save Team'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAddOptions(CaseModel c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Add to Case',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 20),
              _addOption(Icons.group_add, 'Manage Team', () {
                Navigator.pop(context);
                _showManageTeamSheet(c);
              }),
              _addOption(Icons.task_alt, 'Add Task', () {
                Navigator.pop(context);
                Navigator.pushNamed(
                  context,
                  '/lawyer-work',
                  arguments: {
                    'tabIndex': 0,
                    'caseId': c.cino,
                    'lockCaseSelection': true,
                  },
                );
              }),
              _addOption(Icons.chat_bubble_outline, 'Open Case Chat', () {
                Navigator.pop(context);
                _createCaseChat(context, c);
              }),
              _addOption(Icons.description, 'Generate Document', () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/document-generator', arguments: c);
              }),
              _addOption(Icons.sos, 'Send SOS', () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/courtroom-sos', arguments: c);
              }),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addOption(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: AppColors.accent),
      ),
      title: Text(label),
      onTap: onTap,
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.text,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

// ==================== COURT CALENDAR ====================
class CourtCalendarScreen extends ConsumerWidget {
  const CourtCalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cases = ref.watch(casesProvider);
    final activeCases = cases.where((c) => !c.isClosed).toList();
    final now = DateTime.now();

    // Build upcoming hearings sorted by date
    final upcoming = activeCases
        .where(
            (c) => c.nextHearingDate != null && c.nextHearingDate!.isAfter(now))
        .toList()
      ..sort((a, b) => a.nextHearingDate!.compareTo(b.nextHearingDate!));

    // Highlighted days in calendar
    final highlightedDays =
        upcoming.map((c) => c.nextHearingDate!.day).toSet().toList();

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
                  'Court Calendar',
                  style: TextStyle(
                      color: AppColors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600),
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
                  AppCard(
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                                icon: Icon(Icons.chevron_left,
                                    color: Colors.grey[400]),
                                onPressed: () {}),
                            Text(DateFormat('MMMM yyyy').format(now),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary)),
                            IconButton(
                                icon: Icon(Icons.chevron_right,
                                    color: Colors.grey[400]),
                                onPressed: () {}),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _buildCalendarGrid(highlightedDays),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Upcoming Hearings (${upcoming.length})',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary)),
                  const SizedBox(height: 12),
                  if (upcoming.isEmpty)
                    AppCard(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text('No upcoming hearings',
                              style: TextStyle(color: Colors.grey[500])),
                        ),
                      ),
                    )
                  else
                    ...upcoming.take(10).map((c) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildHearingCard(c),
                        )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid(List<int> highlightedDays) {
    final days = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    final today = DateTime.now().day;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: days
              .map((d) => Text(d,
                  style: TextStyle(color: Colors.grey[400], fontSize: 12)))
              .toList(),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7),
          itemCount: 31,
          itemBuilder: (context, index) {
            final day = index + 1;
            final isHighlighted = highlightedDays.contains(day);
            final isToday = day == today;
            return Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isHighlighted
                      ? AppColors.primary
                      : (isToday ? AppColors.accent.withOpacity(0.3) : null),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Text(
                    '$day',
                    style: TextStyle(
                      color: isHighlighted ? AppColors.white : AppColors.text,
                      fontSize: 14,
                      fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildHearingCard(CaseModel c) {
    return AppCard(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.urgencyColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text('${c.nextHearingDate!.day}',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: c.urgencyColor)),
                Text(DateFormat('MMM').format(c.nextHearingDate!),
                    style: TextStyle(fontSize: 12, color: c.urgencyColor)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, color: AppColors.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(c.courtComplex,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Row(
                  children: [
                    const Icon(Icons.gavel, size: 12, color: AppColors.accent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(c.currentStage,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.accent),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.notifications, color: AppColors.accent, size: 20),
        ],
      ),
    );
  }
}

// ==================== LAWYER TASKS SCREEN ====================
class LawyerTasksScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;
  final String? initialCaseId;
  final bool lockCaseSelection;

  const LawyerTasksScreen({
    super.key,
    this.isEmbedded = false,
    this.initialCaseId,
    this.lockCaseSelection = false,
  });

  @override
  ConsumerState<LawyerTasksScreen> createState() => _LawyerTasksScreenState();
}

class _LawyerTasksScreenState extends ConsumerState<LawyerTasksScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late bool _isInternMode;
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  String _visibility = 'private';
  List<String> _selectedMemberIds = [];
  DateTime _deadline = DateTime.now().add(const Duration(days: 3));
  bool _autoEscalate = true;
  String? _selectedCaseId;

  @override
  void initState() {
    super.initState();
    _isInternMode = ref.read(currentUserProvider)?.role == 'intern';
    _tabController = TabController(length: _isInternMode ? 2 : 3, vsync: this);
    _selectedCaseId = widget.initialCaseId;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(20, widget.isEmbedded ? 0 : 60, 20, 0),
            color: AppColors.primary,
            child: Column(
              children: [
                if (!widget.isEmbedded)
                  Row(
                    children: [
                      _buildBackButton(context),
                      const SizedBox(width: 12),
                      const Text('Tasks',
                          style: TextStyle(
                              color: AppColors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                if (!widget.isEmbedded) const SizedBox(height: 16),
                TabBar(
                  controller: _tabController,
                  labelColor: AppColors.accent,
                  unselectedLabelColor: Colors.grey[400],
                  indicatorColor: AppColors.accent,
                  indicatorWeight: 3,
                  tabs: _isInternMode
                      ? const [
                          Tab(text: 'In Progress'),
                          Tab(text: 'Completed'),
                        ]
                      : const [
                          Tab(text: 'Create Task'),
                          Tab(text: 'In Progress'),
                          Tab(text: 'Completed'),
                        ],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: _isInternMode
                  ? [
                      _buildTaskListTab(completed: false),
                      _buildTaskListTab(completed: true),
                    ]
                  : [
                      _buildCreateTaskTab(),
                      _buildTaskListTab(completed: false),
                      _buildTaskListTab(completed: true),
                    ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateTaskTab() {
    final cases = ref.watch(casesProvider);
    final members = ref.watch(firmMembersProvider);
    final currentUser = ref.watch(currentUserProvider);
    final isInternUser = currentUser?.role == 'intern';
    final activeCases = cases.where((c) => !c.isClosed).toList();
    final selectedTaskCaseExists = _selectedCaseId != null &&
        activeCases.any((c) => c.cino == _selectedCaseId);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Task Title',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            decoration: InputDecoration(
              hintText: 'Enter task title',
              filled: true,
              fillColor: AppColors.white,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 20),

          const Text('Description',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          TextField(
            controller: _descriptionController,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'Enter task description',
              filled: true,
              fillColor: AppColors.white,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 20),

          // Case selector
          const Text('Link to Case (Optional)',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          if (widget.lockCaseSelection)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                activeCases
                        .where((c) => c.cino == _selectedCaseId)
                        .firstOrNull
                        ?.title ??
                    (_selectedCaseId ?? 'Selected case'),
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  color: AppColors.text,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: selectedTaskCaseExists ? _selectedCaseId : null,
                  hint: Text('Select case',
                      style: TextStyle(color: Colors.grey[400])),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('No case linked')),
                    ...activeCases.map((c) => DropdownMenuItem(
                        value: c.cino,
                        child: Text(c.title, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setState(() {
                    _selectedCaseId = v;
                    if (v == null || !widget.lockCaseSelection) return;
                    final selectedCase =
                        activeCases.where((c) => c.cino == v).firstOrNull;
                    final allowedIds = Set<String>.from(
                        selectedCase?.assignedMemberIds ?? const []);
                    _selectedMemberIds
                        .removeWhere((id) => !allowedIds.contains(id));
                  }),
                ),
              ),
            ),
          if (_selectedCaseId != null && !widget.lockCaseSelection) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _deleteSelectedCaseFromTaskForm,
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.error, size: 16),
                label: const Text('Clear case selection',
                    style: TextStyle(color: AppColors.error)),
              ),
            ),
          ],
          const SizedBox(height: 20),

          if (!isInternUser) ...[
            const Text('Visibility',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: AppColors.text)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child:
                      _buildVisibilityOption('private', Icons.lock, 'Private'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      _buildVisibilityOption('lawyers', Icons.gavel, 'Lawyers'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildVisibilityOption(
                      'interns', Icons.school, 'Interns'),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ] else ...[
            const Text('Assignee',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: AppColors.text)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: const Text('You (self-assigned)'),
            ),
            const SizedBox(height: 20),
          ],

          // Member selection
          if (!isInternUser &&
              (_visibility == 'lawyers' || _visibility == 'interns'))
            members.when(
              data: (memberList) {
                final roleFilter =
                    _visibility == 'lawyers' ? 'lawyer' : 'intern';

                // Restrict to case members only for locked case-specific task flow.
                final CaseModel? selectedCase = _selectedCaseId != null
                    ? activeCases
                        .where((c) => c.cino == _selectedCaseId)
                        .firstOrNull
                    : null;

                final caseMemberIds = selectedCase?.assignedMemberIds ?? [];

                final filteredMembers = memberList.where((m) {
                  if ((m.role as String).toLowerCase() != roleFilter ||
                      m.uid == currentUser?.uid) {
                    return false;
                  }
                  if (widget.lockCaseSelection &&
                      selectedCase != null &&
                      !caseMemberIds.contains(m.uid)) return false;
                  return true;
                }).toList();

                final allSelected = filteredMembers.isNotEmpty &&
                    filteredMembers
                        .every((m) => _selectedMemberIds.contains(m.uid));

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Assign To',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppColors.text)),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              if (allSelected) {
                                // Deselect all that match the filter
                                for (final m in filteredMembers) {
                                  _selectedMemberIds.remove(m.uid);
                                }
                              } else {
                                // Select all that match the filter
                                for (final m in filteredMembers) {
                                  if (!_selectedMemberIds.contains(m.uid)) {
                                    _selectedMemberIds.add(m.uid);
                                  }
                                }
                              }
                            });
                          },
                          child: Text(
                              allSelected ? 'Deselect All' : 'Select All',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.accent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (filteredMembers.isEmpty)
                      Text(
                          widget.lockCaseSelection && selectedCase != null
                          ? 'No $roleFilter members assigned to this case. Manage members in Case Details.'
                          : 'No members found for this role.',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 13)),
                    ...filteredMembers.map((m) {
                      final selected = _selectedMemberIds.contains(m.uid);
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selectedMemberIds.remove(m.uid);
                            } else {
                              _selectedMemberIds.add(m.uid);
                            }
                          });
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.accent.withOpacity(0.1)
                                : AppColors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: selected
                                    ? AppColors.accent
                                    : Colors.grey[300]!,
                                width: 2),
                          ),
                          child: Row(
                            children: [
                              AvatarCircle(initials: m.initials, size: 36),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.name,
                                      style: TextStyle(
                                          fontWeight: selected
                                              ? FontWeight.w600
                                              : FontWeight.w500)),
                                  Text(m.role,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey[500])),
                                ],
                              )),
                              if (selected)
                                const Icon(Icons.check_circle,
                                    color: AppColors.accent, size: 20),
                            ],
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 20),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error loading members: $e'),
            ),

          const Text('Deadline',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: _deadline,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (date != null) setState(() => _deadline = date);
            },
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, color: AppColors.accent),
                  const SizedBox(width: 12),
                  Text(DateFormat('dd/MM/yyyy').format(_deadline),
                      style: const TextStyle(color: AppColors.text)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          if (!isInternUser) ...[
            AppCard(
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Auto-escalate',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        Text('Make visible to all if overdue',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _autoEscalate,
                    onChanged: (v) => setState(() => _autoEscalate = v),
                    activeColor: AppColors.accent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _createTask,
              child: const Text('Create Task'),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  void _createTask() {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please enter a title')));
      return;
    }

    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final isInternUser = user.role == 'intern';

    if (isInternUser) {
      _visibility = 'private';
      _selectedMemberIds = [user.uid];
      _autoEscalate = false;
    }

    if (!isInternUser &&
        _visibility != 'private' &&
        _selectedMemberIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one member.')),
      );
      return;
    }

    if (widget.lockCaseSelection &&
        _selectedCaseId != null &&
        (_visibility == 'lawyers' || _visibility == 'interns')) {
      final cases = ref.read(casesProvider);
      final selectedCase =
          cases.where((c) => c.cino == _selectedCaseId).firstOrNull;
      final caseMemberIds =
          Set<String>.from(selectedCase?.assignedMemberIds ?? const []);
      if (_selectedMemberIds.any((id) => !caseMemberIds.contains(id))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Only members assigned to this case can be selected.')),
        );
        return;
      }
    }

    final participants = <String>{user.uid};

    if (_visibility == 'lawyers' || _visibility == 'interns' || isInternUser) {
      participants.addAll(_selectedMemberIds);
    }

    final taskId = _uuid.v4();
    final task = {
      'id': taskId,
      'title': _titleController.text.trim(),
      'description': _descriptionController.text.trim(),
      'type': 'task',
      'caseId': _selectedCaseId,
      'createdBy': user.uid,
      'createdByName': user.name,
      'deadline': _deadline.toIso8601String(),
      'visibility': isInternUser ? 'private' : _visibility,
      'assignedJuniorIds': isInternUser ? [user.uid] : _selectedMemberIds,
      'participantIds': participants.toList(),
      'status': 'pending',
      'autoEscalate': isInternUser ? false : _autoEscalate,
      'isEscalated': false,
      'isPublic': false,
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    };

    ref.read(tasksProvider.notifier).addTask(task);

    // Schedule deadline reminder
    NotificationService.scheduleDeadlineReminder(
      id: taskId.hashCode,
      title: 'Deadline Reminder',
      body: 'Task "${_titleController.text}" is due in 2 hours!',
      scheduledTime: _deadline.subtract(const Duration(hours: 2)),
    );

    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task created successfully')));
    _tabController.animateTo(1);
    _titleController.clear();
    _descriptionController.clear();
    setState(() {
      _selectedMemberIds.clear();
      _selectedCaseId = null;
    });
  }

  Future<void> _deleteSelectedCaseFromTaskForm() async {
    final caseId = _selectedCaseId;
    if (caseId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Linked Case?'),
        content: const Text(
            'This will delete the selected case from your case list.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await ref.read(casesProvider.notifier).deleteCase(caseId);
    if (!mounted) return;
    setState(() => _selectedCaseId = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Selected case deleted'),
          backgroundColor: AppColors.error),
    );
  }

  Widget _buildVisibilityOption(String value, IconData icon, String label) {
    bool isSelected = _visibility == value;
    return GestureDetector(
      onTap: () => setState(() {
        _visibility = value;
        if (value == 'private') {
          _selectedMemberIds.clear();
        }
      }),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:
              isSelected ? AppColors.accent.withOpacity(0.15) : AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isSelected ? AppColors.accent : Colors.grey[300]!,
              width: 2),
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? AppColors.accent : Colors.grey[400]),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: AppColors.text)),
          ],
        ),
      ),
    );
  }

  String _taskStatusLabel(String status) {
    switch (status) {
      case 'inProgress':
        return 'IN PROGRESS';
      case 'completed':
        return 'COMPLETED';
      case 'overdue':
        return 'OVERDUE';
      default:
        return 'PENDING';
    }
  }

  Future<void> _setTaskStatus(Map<String, dynamic> task, String status) async {
    await ref
        .read(tasksProvider.notifier)
        .updateTask(task['id'], {'status': status});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Task marked as ${_taskStatusLabel(status)}')),
    );
  }

  Future<void> _showEditTaskDialog(Map<String, dynamic> task) async {
    final titleController = TextEditingController(text: task['title'] ?? '');
    final descriptionController =
        TextEditingController(text: task['description'] ?? '');
    DateTime selectedDeadline = task['deadline'] != null
        ? DateTime.tryParse(task['deadline']) ?? DateTime.now()
        : DateTime.now();

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Edit Task'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descriptionController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Description'),
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: selectedDeadline,
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 3650)),
                      );
                      if (picked != null) {
                        setDialogState(() => selectedDeadline = picked);
                      }
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                      'Deadline: ${DateFormat('dd/MM/yyyy').format(selectedDeadline)}',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );

    if (shouldSave != true) return;
    if (titleController.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task title cannot be empty')),
      );
      return;
    }

    await ref.read(tasksProvider.notifier).updateTask(task['id'], {
      'title': titleController.text.trim(),
      'description': descriptionController.text.trim(),
      'deadline': selectedDeadline.toIso8601String(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Task updated successfully')),
    );
  }

  Widget _buildTaskListTab({required bool completed}) {
    final user = ref.watch(currentUserProvider);
    final isInternUser = user?.role == 'intern';
    final allTasks = ref.watch(tasksProvider);
    final filtered = allTasks.where((t) {
      final uid = user?.uid ?? '';
      final assigned = List<String>.from(t['assignedJuniorIds'] ?? const []);
      final participants = List<String>.from(t['participantIds'] ?? const []);
      final isOwner = t['createdBy'] == uid;
      final isPublic = t['isPublic'] == true;
      final isAssigned = assigned.contains(uid);
      final isParticipant = participants.contains(uid);
      final isCompleted = t['status'] == 'completed';
      final isVisibleToUser = isOwner || isPublic || isAssigned || isParticipant;
      return isVisibleToUser && (completed ? isCompleted : !isCompleted);
    }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Text(completed ? 'No completed tasks' : 'No active tasks',
            style: TextStyle(color: Colors.grey[500])),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final task = filtered[index];
        final isEscalated = task['isEscalated'] == true;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4))
            ],
            border: isEscalated
                ? Border.all(color: AppColors.error, width: 2)
                : null,
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            title: Row(
              children: [
                if (isEscalated)
                  const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.warning,
                          color: AppColors.error, size: 16)),
                Expanded(
                    child: Text(task['title'] ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isEscalated
                        ? AppColors.error.withOpacity(0.1)
                        : (task['status'] == 'completed'
                            ? AppColors.success.withOpacity(0.1)
                        : task['status'] == 'inProgress'
                          ? Colors.blue.withOpacity(0.1)
                            : AppColors.warning.withOpacity(0.1)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isEscalated
                        ? 'ESCALATED'
                        : _taskStatusLabel((task['status'] ?? 'pending').toString()),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isEscalated
                          ? AppColors.error
                          : (task['status'] == 'completed'
                              ? AppColors.success
                            : task['status'] == 'inProgress'
                              ? Colors.blue
                              : AppColors.warning),
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(task['description'] ?? '',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.calendar_today,
                        size: 12, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      task['deadline'] != null
                          ? 'Due: ${DateFormat('MMM d').format(DateTime.parse(task['deadline']))}'
                          : 'No deadline',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ],
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  _showEditTaskDialog(task);
                  return;
                }
                if (value == 'status_pending') {
                  _setTaskStatus(task, 'pending');
                  return;
                }
                if (value == 'status_inProgress') {
                  _setTaskStatus(task, 'inProgress');
                  return;
                }
                if (value == 'status_completed') {
                  _setTaskStatus(task, 'completed');
                  return;
                }
                if (value == 'delete') {
                  if (isInternUser) return;
                  ref.read(tasksProvider.notifier).deleteTask(task['id']);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem<String>(
                  value: 'edit',
                  child: Text('Edit Task'),
                ),
                const PopupMenuItem<String>(
                  value: 'status_pending',
                  child: Text('Mark Pending'),
                ),
                const PopupMenuItem<String>(
                  value: 'status_inProgress',
                  child: Text('Mark In Progress'),
                ),
                const PopupMenuItem<String>(
                  value: 'status_completed',
                  child: Text('Mark Completed'),
                ),
                if (!isInternUser)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('Delete Task'),
                  ),
              ],
            ),
            onTap: () => _showEditTaskDialog(task),
          ),
        );
      },
    );
  }
}

// ==================== LAWYER ASSIGNMENTS SCREEN ====================
class LawyerAssignmentsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;
  const LawyerAssignmentsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<LawyerAssignmentsScreen> createState() =>
      _LawyerAssignmentsScreenState();
}

class _LawyerAssignmentsScreenState
    extends ConsumerState<LawyerAssignmentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late bool _isInternMode;
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  String _visibility = 'private';
  List<String> _selectedAssigneeIds = [];
  String _tag = 'normal';
  DateTime _deadline = DateTime.now().add(const Duration(days: 3));
  String? _selectedCaseId;

  @override
  void initState() {
    super.initState();
    _isInternMode = ref.read(currentUserProvider)?.role == 'intern';
    _tabController = TabController(length: _isInternMode ? 2 : 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(20, widget.isEmbedded ? 0 : 60, 20, 0),
            color: AppColors.primary,
            child: Column(
              children: [
                if (!widget.isEmbedded)
                  Row(
                    children: [
                      _buildBackButton(context),
                      const SizedBox(width: 12),
                      const Text('Assignments',
                          style: TextStyle(
                              color: AppColors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                if (!widget.isEmbedded) const SizedBox(height: 16),
                TabBar(
                  controller: _tabController,
                  labelColor: AppColors.accent,
                  unselectedLabelColor: Colors.grey[400],
                  indicatorColor: AppColors.accent,
                  indicatorWeight: 3,
                  tabs: _isInternMode
                      ? const [
                          Tab(text: 'In Progress'),
                          Tab(text: 'Completed'),
                        ]
                      : const [
                          Tab(text: 'Create Assignment'),
                          Tab(text: 'In Progress'),
                          Tab(text: 'Completed'),
                        ],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: _isInternMode
                  ? [
                      _buildAssignmentListTab(completed: false),
                      _buildAssignmentListTab(completed: true),
                    ]
                  : [
                      _buildCreateTab(),
                      _buildAssignmentListTab(completed: false),
                      _buildAssignmentListTab(completed: true),
                    ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateTab() {
    final user = ref.watch(currentUserProvider);
    final isInternUser = user?.role == 'intern';
    final cases = ref.watch(casesProvider);
    final members = ref.watch(firmMembersProvider);
    final activeCases = cases.where((c) => !c.isClosed).toList();
    final selectedAssignmentCaseExists = _selectedCaseId != null &&
        activeCases.any((c) => c.cino == _selectedCaseId);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Assignment Title',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            decoration: InputDecoration(
              hintText: 'Enter title',
              filled: true,
              fillColor: AppColors.white,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 20),

          const Text('Description',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          TextField(
            controller: _descriptionController,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'Enter description',
              filled: true,
              fillColor: AppColors.white,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 20),

          // Case Selector
          const Text('Link to Case',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.white,
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedAssignmentCaseExists ? _selectedCaseId : null,
                hint: Text('Select case',
                    style: TextStyle(color: Colors.grey[400])),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  ...activeCases.map((c) => DropdownMenuItem(
                      value: c.cino,
                      child: Text(c.title, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) => setState(() => _selectedCaseId = v),
              ),
            ),
          ),
          if (_selectedCaseId != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _deleteSelectedCaseFromAssignmentForm,
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.error, size: 16),
                label: const Text('Delete selected case',
                    style: TextStyle(color: AppColors.error)),
              ),
            ),
          ],
          const SizedBox(height: 20),

          if (!isInternUser) ...[
            const Text('Visibility',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: AppColors.text)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child:
                      _buildVisibilityOption('private', Icons.lock, 'Private'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      _buildVisibilityOption('lawyers', Icons.gavel, 'Lawyers'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildVisibilityOption(
                      'interns', Icons.school, 'Interns'),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ] else ...[
            const Text('Assignee',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: AppColors.text)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: const Text('You (self-assigned)'),
            ),
            const SizedBox(height: 20),
          ],

          // Member selection
          if (!isInternUser &&
              (_visibility == 'lawyers' || _visibility == 'interns'))
            members.when(
              data: (memberList) {
                final roleFilter =
                    _visibility == 'lawyers' ? 'lawyer' : 'intern';
                final filteredMembers = memberList
                    .where((m) =>
                        (m.role as String).toLowerCase() == roleFilter &&
                        m.uid != user?.uid)
                    .toList();

                final allSelected = filteredMembers.isNotEmpty &&
                    filteredMembers
                        .every((m) => _selectedAssigneeIds.contains(m.uid));

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Assign To',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppColors.text)),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              if (allSelected) {
                                for (final m in filteredMembers) {
                                  _selectedAssigneeIds.remove(m.uid);
                                }
                              } else {
                                for (final m in filteredMembers) {
                                  if (!_selectedAssigneeIds.contains(m.uid)) {
                                    _selectedAssigneeIds.add(m.uid);
                                  }
                                }
                              }
                            });
                          },
                          child: Text(
                              allSelected ? 'Deselect All' : 'Select All',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.accent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (filteredMembers.isEmpty)
                      const Text('No members found for this role.',
                          style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ...filteredMembers.map((m) {
                      final selected = _selectedAssigneeIds.contains(m.uid);
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selectedAssigneeIds.remove(m.uid);
                            } else {
                              _selectedAssigneeIds.add(m.uid);
                            }
                          });
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.accent.withOpacity(0.1)
                                : AppColors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: selected
                                    ? AppColors.accent
                                    : Colors.grey[300]!,
                                width: 2),
                          ),
                          child: Row(
                            children: [
                              AvatarCircle(initials: m.initials, size: 36),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.name,
                                      style: TextStyle(
                                          fontWeight: selected
                                              ? FontWeight.w600
                                              : FontWeight.w500)),
                                  Text(m.role,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey[500])),
                                ],
                              )),
                              if (selected)
                                const Icon(Icons.check_circle,
                                    color: AppColors.accent, size: 20),
                            ],
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 20),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error: $e'),
            ),

          const Text('Priority',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          Row(
            children: [
              _priorityOption('urgent', Icons.local_fire_department, 'Urgent',
                  AppColors.error),
              const SizedBox(width: 8),
              _priorityOption('highPriority', Icons.priority_high, 'High',
                  AppColors.warning),
              const SizedBox(width: 8),
              _priorityOption('normal', Icons.check_circle_outline, 'Normal',
                  AppColors.success),
            ],
          ),
          const SizedBox(height: 20),

          // Deadline
          const Text('Deadline',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.text)),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: _deadline,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (date != null) setState(() => _deadline = date);
            },
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, color: AppColors.accent),
                  const SizedBox(width: 12),
                  Text(DateFormat('dd/MM/yyyy').format(_deadline)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _createAssignment,
              child: const Text('Create Assignment'),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildVisibilityOption(String value, IconData icon, String label) {
    bool isSelected = _visibility == value;
    return GestureDetector(
      onTap: () => setState(() {
        _visibility = value;
        if (value == 'private') {
          _selectedAssigneeIds.clear();
        }
      }),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:
              isSelected ? AppColors.accent.withOpacity(0.15) : AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isSelected ? AppColors.accent : Colors.grey[300]!,
              width: 2),
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? AppColors.accent : Colors.grey[400]),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: AppColors.text)),
          ],
        ),
      ),
    );
  }

  Widget _priorityOption(
      String value, IconData icon, String label, Color color) {
    final isSelected = _tag == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tag = value),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected ? color.withOpacity(0.15) : AppColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: isSelected ? color : Colors.grey[300]!, width: 2),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: color),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  void _createAssignment() {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please enter a title')));
      return;
    }

    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final isInternUser = user.role == 'intern';

    if (isInternUser) {
      _visibility = 'private';
      _selectedAssigneeIds = [user.uid];
    }

    if (!isInternUser &&
        _visibility != 'private' &&
        _selectedAssigneeIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select at least one assignee')));
      return;
    }

    final members = ref.read(firmMembersProvider).valueOrNull ?? [];
    String assigneeName = 'Self-Assigned';
    if (_visibility != 'private' && !isInternUser) {
      final selectedMembers = members
          .where((m) => _selectedAssigneeIds.contains(m.uid))
          .map((m) => m.name)
          .toList();
      assigneeName = selectedMembers.join(', ');
    }

    final assignmentId = _uuid.v4();
    final assignment = {
      'id': assignmentId,
      'title': _titleController.text.trim(),
      'description': _descriptionController.text.trim(),
      'type': 'assignment',
      'caseId': _selectedCaseId,
      'createdBy': user.uid,
      'createdByName': user.name,
      'deadline': _deadline.toIso8601String(),
      'assignedToIds': isInternUser
          ? [user.uid]
          : (_visibility == 'private' ? [user.uid] : _selectedAssigneeIds),
      'assignedToName': isInternUser ? user.name : assigneeName,
      'participantIds': <String>[
        user.uid,
        ...(isInternUser || _visibility == 'private'
            ? []
            : _selectedAssigneeIds)
      ],
      'tag': _tag,
      'status': 'pending',
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    };

    // Save to Hive + sync
    ref.read(assignmentsProvider.notifier).addAssignment(assignment);

    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Assignment created successfully')));
    _tabController.animateTo(1);
    _titleController.clear();
    _descriptionController.clear();
    setState(() {
      _selectedAssigneeIds.clear();
      _selectedCaseId = null;
      _visibility = 'private';
    });
  }

  Future<void> _deleteSelectedCaseFromAssignmentForm() async {
    final caseId = _selectedCaseId;
    if (caseId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Linked Case?'),
        content: const Text(
            'This will delete the selected case from your case list.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await ref.read(casesProvider.notifier).deleteCase(caseId);
    if (!mounted) return;
    setState(() => _selectedCaseId = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Selected case deleted'),
          backgroundColor: AppColors.error),
    );
  }

  String _assignmentStatusLabel(String status) {
    switch (status) {
      case 'inProgress':
        return 'IN PROGRESS';
      case 'completed':
        return 'COMPLETED';
      case 'overdue':
        return 'OVERDUE';
      default:
        return 'PENDING';
    }
  }

  Future<void> _setAssignmentStatus(
      Map<String, dynamic> assignment, String status) async {
    await ref
        .read(assignmentsProvider.notifier)
        .updateAssignment(assignment['id'], {'status': status});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Assignment marked as ${_assignmentStatusLabel(status)}')),
    );
  }

  Future<void> _showEditAssignmentDialog(Map<String, dynamic> assignment) async {
    final titleController =
        TextEditingController(text: assignment['title'] ?? '');
    final descriptionController =
        TextEditingController(text: assignment['description'] ?? '');
    DateTime selectedDeadline = assignment['deadline'] != null
        ? DateTime.tryParse(assignment['deadline']) ?? DateTime.now()
        : DateTime.now();
    String selectedTag = (assignment['tag'] ?? 'normal').toString();

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Edit Assignment'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descriptionController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Description'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: selectedTag,
                    decoration: const InputDecoration(labelText: 'Priority'),
                    items: const [
                      DropdownMenuItem(value: 'urgent', child: Text('Urgent')),
                      DropdownMenuItem(
                          value: 'highPriority', child: Text('High')),
                      DropdownMenuItem(value: 'normal', child: Text('Normal')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => selectedTag = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: selectedDeadline,
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 3650)),
                      );
                      if (picked != null) {
                        setDialogState(() => selectedDeadline = picked);
                      }
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                        'Deadline: ${DateFormat('dd/MM/yyyy').format(selectedDeadline)}'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );

    if (shouldSave != true) return;
    if (titleController.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Assignment title cannot be empty')),
      );
      return;
    }

    await ref.read(assignmentsProvider.notifier).updateAssignment(
      assignment['id'],
      {
        'title': titleController.text.trim(),
        'description': descriptionController.text.trim(),
        'deadline': selectedDeadline.toIso8601String(),
        'tag': selectedTag,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Assignment updated successfully')),
    );
  }

  Widget _buildAssignmentListTab({required bool completed}) {
    final user = ref.watch(currentUserProvider);
    final isInternUser = user?.role == 'intern';
    final assignments = ref
        .watch(assignmentsProvider)
        .where((a) =>
            a['createdBy'] == user?.uid ||
        List<String>.from(a['assignedToIds'] ?? const [])
          .contains(user?.uid) ||
        List<String>.from(a['participantIds'] ?? const [])
          .contains(user?.uid) ||
        (a['assignedToId'] ?? '').toString() == (user?.uid ?? ''))
        .where((a) => completed
            ? (a['status'] ?? 'pending') == 'completed'
            : (a['status'] ?? 'pending') != 'completed')
        .toList()
      ..sort((a, b) => (b['createdAt'] ?? '')
          .toString()
          .compareTo((a['createdAt'] ?? '').toString()));

    if (assignments.isEmpty) {
      return Center(
          child: Text(
              completed ? 'No completed assignments' : 'No active assignments',
              style: const TextStyle(color: Colors.grey)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: assignments.length,
      itemBuilder: (context, index) {
        final a = assignments[index];
        final tagColor = a['tag'] == 'urgent'
            ? AppColors.error
            : a['tag'] == 'highPriority'
                ? AppColors.warning
                : AppColors.success;
        final statusColor = a['status'] == 'completed'
          ? AppColors.success
          : a['status'] == 'inProgress'
            ? Colors.blue
            : a['status'] == 'overdue'
              ? AppColors.error
              : AppColors.warning;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4))
            ],
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            title: Row(
              children: [
                Expanded(
                    child: Text(a['title'] ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: tagColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    (a['tag'] ?? 'normal').toString().toUpperCase(),
                    style: TextStyle(
                        fontSize: 10,
                        color: tagColor,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  'From: ${a['createdByName'] ?? 'Unknown'} • To: ${a['assignedToName'] ?? 'Unknown'}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.primary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(a['description'] ?? '',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.calendar_today,
                        size: 12, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      a['deadline'] != null
                          ? 'Due: ${DateFormat('MMM d').format(DateTime.parse(a['deadline']))}'
                          : '',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _assignmentStatusLabel(
                            (a['status'] ?? 'pending').toString()),
                        style: TextStyle(
                            fontSize: 10,
                            color: statusColor,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  _showEditAssignmentDialog(a);
                  return;
                }
                if (value == 'status_pending') {
                  _setAssignmentStatus(a, 'pending');
                  return;
                }
                if (value == 'status_inProgress') {
                  _setAssignmentStatus(a, 'inProgress');
                  return;
                }
                if (value == 'status_completed') {
                  _setAssignmentStatus(a, 'completed');
                  return;
                }
                if (value == 'delete') {
                  if (isInternUser) return;
                  ref
                      .read(assignmentsProvider.notifier)
                      .deleteAssignment(a['id']);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem<String>(
                  value: 'edit',
                  child: Text('Edit Assignment'),
                ),
                const PopupMenuItem<String>(
                  value: 'status_pending',
                  child: Text('Mark Pending'),
                ),
                const PopupMenuItem<String>(
                  value: 'status_inProgress',
                  child: Text('Mark In Progress'),
                ),
                const PopupMenuItem<String>(
                  value: 'status_completed',
                  child: Text('Mark Completed'),
                ),
                if (!isInternUser)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('Delete Assignment'),
                  ),
              ],
            ),
            onTap: () => _showEditAssignmentDialog(a),
          ),
        );
      },
    );
  }
}

// ==================== LAWYER WORK SCREEN (Tabs) ====================
class LawyerWorkScreen extends StatefulWidget {
  final int initialTabIndex;

  const LawyerWorkScreen({super.key, this.initialTabIndex = 0});

  @override
  State<LawyerWorkScreen> createState() => _LawyerWorkScreenState();
}

class _LawyerWorkScreenState extends State<LawyerWorkScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _appliedRouteTab = false;
  String? _routeCaseId;
  bool _routeLockCaseSelection = false;

  @override
  void initState() {
    super.initState();
    final startTab = widget.initialTabIndex.clamp(0, 1);
    _tabController =
        TabController(length: 2, vsync: this, initialIndex: startTab);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_appliedRouteTab) return;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['tabIndex'] is int) {
      final idx = (args['tabIndex'] as int).clamp(0, 1);
      if (_tabController.index != idx) {
        _tabController.index = idx;
      }
    }
    if (args is Map && args['caseId'] is String) {
      _routeCaseId = (args['caseId'] as String).trim();
      if (_routeCaseId != null && _routeCaseId!.isEmpty) {
        _routeCaseId = null;
      }
    }
    if (args is Map && args['lockCaseSelection'] is bool) {
      _routeLockCaseSelection = args['lockCaseSelection'] as bool;
    }
    if (_routeCaseId != null) {
      _routeLockCaseSelection = true;
    }
    _appliedRouteTab = true;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 0),
            color: AppColors.primary,
            child: Column(
              children: [
                const Text(
                  'My Work',
                  style: TextStyle(
                      color: AppColors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                TabBar(
                  controller: _tabController,
                  labelColor: AppColors.accent,
                  unselectedLabelColor: Colors.grey[400],
                  indicatorColor: AppColors.accent,
                  indicatorWeight: 3,
                  tabs: const [
                    Tab(text: 'Tasks'),
                    Tab(text: 'Assignments'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                LawyerTasksScreen(
                  isEmbedded: true,
                  initialCaseId: _routeCaseId,
                  lockCaseSelection: _routeLockCaseSelection,
                ),
                LawyerAssignmentsScreen(isEmbedded: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== HELPER ====================
Widget _buildBackButton(BuildContext context) {
  return GestureDetector(
    onTap: () => Navigator.pop(context),
    child: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Icon(Icons.arrow_back, color: AppColors.white, size: 20),
    ),
  );
}
