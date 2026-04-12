import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../main.dart';
import '../widgets/common_widgets.dart';
import '../providers/providers.dart';
import '../services/notification_service.dart';
import '../utils/date_formatter.dart';

// ==================== INTERN DASHBOARD ====================
class InternDashboard extends ConsumerStatefulWidget {
  const InternDashboard({super.key});

  @override
  ConsumerState<InternDashboard> createState() => _InternDashboardState();
}

class _InternDashboardState extends ConsumerState<InternDashboard> with WidgetsBindingObserver {
  int _currentNavIndex = 0;
  final Set<String> _seenSosAlertIds = <String>{};
  bool _showSosBlink = false;
  bool _blinkOn = false;
  Timer? _blinkTicker;
  Timer? _blinkStopper;
  StreamSubscription<Map<String, dynamic>>? _sosBlinkSub;

  // ══════════ SINGLE UNIFIED SOS HANDLER ══════════

  void _handleSos({
    required String sosId,
    required String sentBy,
    String senderName = 'Team member',
    String caseName = 'Unknown case',
    String courtRoom = '',
    bool isRecent = true,
  }) {
    if (sosId.isEmpty) return;
    if (_seenSosAlertIds.contains(sosId)) return;
    if (!isRecent) return;

    // Defer processing if app is not in the foreground.
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final isForeground = lifecycleState == AppLifecycleState.resumed || lifecycleState == null;
    if (!isForeground) return;

    _seenSosAlertIds.add(sosId);

    final user = ref.read(currentUserProvider);
    final currentUid = user?.uid ?? '';
    if (sentBy.isNotEmpty && sentBy == currentUid) return;
    if (_showSosBlink) return;

    _triggerSosBlink();
    NotificationService.playSosNotificationAudioFor3Seconds();
    NotificationService.markSosBlinkConsumed(sosId);

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('SOS received from $senderName ($caseName)'),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

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
        final sentAt = DateFormatter.parseDateNullable(
          alert['timestamp'] ?? alert['createdAt'],
        );
        final isRecent = sentAt != null &&
            DateTime.now().difference(sentAt) <= const Duration(minutes: 2);

        _handleSos(
          sosId: id,
          sentBy: (alert['sentBy'] ?? '').toString(),
          senderName: (alert['sentByName'] ?? 'Team member').toString(),
          caseName: (alert['caseName'] ?? 'Unknown case').toString(),
          courtRoom: (alert['courtRoom'] ?? '').toString(),
          isRecent: isRecent,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _blinkTicker?.cancel();
    _blinkStopper?.cancel();
    _sosBlinkSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final user = ref.read(currentUserProvider);
      final uid = user?.uid ?? '';
      if (uid.isNotEmpty) {
        final memoryBlinks = NotificationService.consumePendingSosBlinks();
        for (final blink in memoryBlinks) {
          _handleSos(
            sosId: (blink['sosId'] ?? '').toString(),
            sentBy: (blink['sentBy'] ?? '').toString(),
            senderName: (blink['sentByName'] ?? 'Team member').toString(),
            caseName: (blink['caseName'] ?? 'Unknown case').toString(),
            courtRoom: (blink['courtRoom'] ?? '').toString(),
          );
        }

        final currentAlerts = ref.read(sosAlertsProvider);
        _processSosAlerts(currentAlerts, uid);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _sosBlinkSub = NotificationService.sosBlinkStream.listen((data) {
      _handleSos(
        sosId: (data['sosId'] ?? '').toString(),
        sentBy: (data['sentBy'] ?? '').toString(),
        senderName: (data['sentByName'] ?? 'Team member').toString(),
        caseName: (data['caseName'] ?? 'Unknown case').toString(),
        courtRoom: (data['courtRoom'] ?? '').toString(),
      );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final memoryBlinks = NotificationService.consumePendingSosBlinks();
      for (final blink in memoryBlinks) {
        _handleSos(
          sosId: (blink['sosId'] ?? '').toString(),
          sentBy: (blink['sentBy'] ?? '').toString(),
          senderName: (blink['sentByName'] ?? 'Team member').toString(),
          caseName: (blink['caseName'] ?? 'Unknown case').toString(),
          courtRoom: (blink['courtRoom'] ?? '').toString(),
        );
      }

      final hiveBlinks = NotificationService.loadPendingSosBlinksFromHive();
      for (final blink in hiveBlinks) {
        _handleSos(
          sosId: (blink['sosId'] ?? '').toString(),
          sentBy: (blink['sentBy'] ?? '').toString(),
          senderName: (blink['sentByName'] ?? 'Team member').toString(),
          caseName: (blink['caseName'] ?? 'Unknown case').toString(),
          courtRoom: (blink['courtRoom'] ?? '').toString(),
        );
      }

      final user = ref.read(currentUserProvider);
      final uid = user?.uid ?? '';
      if (uid.isNotEmpty) {
        final currentAlerts = ref.read(sosAlertsProvider);
        _processSosAlerts(currentAlerts, uid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    ref.watch(sosAlertsProvider);
    final allCases = ref.watch(casesProvider);
    final allTasks = ref.watch(tasksProvider);
    final allAssignments = ref.watch(assignmentsProvider);

    final uid = user?.uid ?? '';
    ref.listen<AsyncValue<List<Map<String, dynamic>>>>(
      sosAlertsProvider,
      (previous, next) {
        if (uid.isNotEmpty) {
          _processSosAlerts(next, uid);
        }
      },
    );

    final myCases = allCases
        .where((c) => !c.isClosed && c.assignedMemberIds.contains(uid))
        .toList();

    final myPendingTasks = allTasks.where((t) {
      final assignedIds = List<String>.from(t['assignedJuniorIds'] ?? const []);
      final participantIds = List<String>.from(t['participantIds'] ?? const []);
      final isAssigned = assignedIds.contains(uid);
      final isParticipant = participantIds.contains(uid);
      final isOwner = (t['createdBy'] ?? '').toString() == uid;
      final isPublic = t['isPublic'] == true || t['visibility'] == 'everyone';
      final status = (t['status'] ?? 'pending').toString().toLowerCase();
      return status != 'completed' &&
          (isAssigned || isParticipant || isOwner || isPublic);
    }).toList();

    final myPendingAssignments = allAssignments.where((a) {
      final assignedToIds = List<String>.from(a['assignedToIds'] ?? const []);
      final participantIds = List<String>.from(a['participantIds'] ?? const []);
      final isAssignee = assignedToIds.contains(uid);
      final isParticipant = participantIds.contains(uid);
      final isOwner = (a['createdBy'] ?? '').toString() == uid;
      final status = (a['status'] ?? 'pending').toString().toLowerCase();
      return status != 'completed' && (isAssignee || isParticipant || isOwner);
    }).toList();

    final now = DateTime.now();
    bool isToday(DateTime? d) =>
        d != null &&
        d.year == now.year &&
        d.month == now.month &&
        d.day == now.day;

    final todayTaskItems = myPendingTasks
        .where(
            (t) => isToday(DateTime.tryParse((t['deadline'] ?? '').toString())))
        .map((t) => {
              'title': (t['title'] ?? 'Untitled Task').toString(),
              'type': 'Task',
              'deadline': DateTime.tryParse((t['deadline'] ?? '').toString()),
              'caseId': (t['caseId'] ?? '').toString(),
            })
        .toList();

    final todayAssignmentItems = myPendingAssignments
        .where(
            (a) => isToday(DateTime.tryParse((a['deadline'] ?? '').toString())))
        .map((a) => {
              'title': (a['title'] ?? 'Untitled Assignment').toString(),
              'type': 'Assignment',
              'deadline': DateTime.tryParse((a['deadline'] ?? '').toString()),
              'caseId': (a['caseId'] ?? '').toString(),
            })
        .toList();

    final todayWorkItems = [...todayTaskItems, ...todayAssignmentItems];

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
                    Text(
                      'Welcome back',
                      style: TextStyle(
                        color: AppColors.white.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      user?.name ?? 'Intern',
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
                            Navigator.pushNamed(context, '/settings-intern'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AvatarCircle(
                      initials: user?.initials ?? 'IN',
                      size: 40,
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Stats Row
                  Row(
                    children: [
                      Expanded(
                        child: AppCard(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Text(
                                '${myPendingTasks.length + myPendingAssignments.length}',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primary,
                                ),
                              ),
                              Text(
                                'My Work',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AppCard(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Text(
                                '${todayWorkItems.length}',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.error,
                                ),
                              ),
                              Text(
                                'Due Today',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AppCard(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Text(
                                '${myCases.length}',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.secondary,
                                ),
                              ),
                              Text(
                                'My Cases',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Today's Work
                  const Text(
                    "Today's Work",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (todayWorkItems.isEmpty)
                    AppCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'No work due today.',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    )
                  else
                    ...todayWorkItems.take(4).map((item) {
                      final caseId = (item['caseId'] ?? '').toString();
                      final caseTitle = allCases
                          .where((c) => c.cino == caseId)
                          .map((c) => c.title)
                          .cast<String?>()
                          .firstWhere((v) => v != null, orElse: () => null);
                      final deadline = item['deadline'] as DateTime?;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildWorkCard(
                          title: (item['title'] ?? '').toString(),
                          subtitle: caseTitle ??
                              (caseId.isEmpty ? 'No linked case' : caseId),
                          meta: deadline == null
                              ? 'No deadline'
                              : 'Due ${DateFormat('h:mm a').format(deadline)}',
                          type: (item['type'] ?? 'Task').toString(),
                        ),
                      );
                    }),
                  const SizedBox(height: 24),

                  // Quick Tools for Intern
                  const Text(
                    'Quick Tools',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Builder(builder: (context) {
                    final tileWidth =
                        (MediaQuery.of(context).size.width - 52) / 2;
                    return Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _buildToolButton(
                                Icons.sos,
                                'SOS',
                                AppColors.error,
                                () => Navigator.pushNamed(
                                    context, '/courtroom-sos'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildToolButton(
                                Icons.campaign,
                                'Notices',
                                AppColors.secondary,
                                () => Navigator.pushNamed(
                                    context, '/notice-board'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                width: tileWidth,
                                child: _buildToolButton(
                                  Icons.description,
                                  'Doc Generator',
                                  Colors.purple,
                                  () => Navigator.pushNamed(
                                      context, '/document-generator'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(child: SizedBox.shrink()),
                          ],
                        ),
                      ],
                    );
                  }),
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
          if (index == 2) Navigator.pushNamed(context, '/my-cases');
          if (index == 3) Navigator.pushNamed(context, '/personal-calendar');
          if (index == 4) Navigator.pushNamed(context, '/messages');
        },
      ),
    );
  }

  Widget _buildWorkCard({
    required String title,
    required String subtitle,
    required String meta,
    required String type,
  }) {
    return AppCard(
      borderColor:
          type == 'Assignment' ? AppColors.secondary : AppColors.accent,
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: (type == 'Assignment'
                      ? AppColors.secondary
                      : AppColors.accent)
                  .withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              type == 'Assignment' ? Icons.assignment : Icons.task_alt,
              color:
                  type == 'Assignment' ? AppColors.secondary : AppColors.accent,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '$subtitle • ',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                      ),
                    ),
                    Text(
                      meta,
                      style: TextStyle(
                        fontSize: 12,
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
    );
  }

  Widget _buildToolButton(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 15,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey[700],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
